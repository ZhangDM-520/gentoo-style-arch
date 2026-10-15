//! The freshness-gate matrix (`crates/gsa-recipe/src/freshness.rs`):
//! pure `decide()` verdicts against the exact §H.3 reason keys, plus the IO
//! helpers driven through PATH stubs (git/pacman/svn/hg/bzr) with an injected
//! sleeper so nothing here ever sleeps or touches the network.
//!
//! Scratch lives under `CARGO_TARGET_TMPDIR` (never `/tmp`); every test that
//! mutates process env (PATH/TMPDIR/GSA_VCS_SKIP_TOLERANCE) holds `ENV_LOCK`,
//! so the harness's parallel threads cannot race the environment.
//!
//! Red-first: every family carries a mutated-input negative alongside its
//! happy path (tampered manifest sha, at-tolerance distance, exit-2 retry
//! count, fail-closed payload map entries, …) so each check is proven able to
//! fail.

use std::ffi::OsString;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Mutex, MutexGuard};
use std::time::{Duration, UNIX_EPOCH};

use gsa_recipe::freshness::*;
use gsa_recipe::VcsKind;

// ---------------------------------------------------------------------------
// Harness: scratch dirs, env guard, PATH stubs
// ---------------------------------------------------------------------------

static ENV_LOCK: Mutex<()> = Mutex::new(());

struct EnvRestore(Vec<(&'static str, Option<OsString>)>);

impl Drop for EnvRestore {
    fn drop(&mut self) {
        for (key, value) in self.0.drain(..) {
            match value {
                Some(value) => std::env::set_var(key, value),
                None => std::env::remove_var(key),
            }
        }
    }
}

/// One test's private scratch + PATH stub dir + restored environment.
/// Field order is load-bearing: fields drop in declaration order, so
/// `_restore` must be declared BEFORE `_lock` — the environment is restored
/// while ENV_LOCK is still held, never after it is released (a later test
/// could otherwise acquire the lock, swap PATH to its own stubs, and have
/// this test's still-pending restore clobber them).
struct Fixture {
    #[allow(dead_code)]
    dir: PathBuf,
    stubs: PathBuf,
    recipe: PathBuf,
    log: PathBuf,
    _restore: EnvRestore,
    _lock: MutexGuard<'static, ()>,
}

fn write_script(path: &Path, body: &str) {
    fs::write(path, format!("#!/bin/bash\n{body}\n")).unwrap();
    let mut perm = fs::metadata(path).unwrap().permissions();
    perm.set_mode(0o755);
    fs::set_permissions(path, perm).unwrap();
}

impl Fixture {
    fn new(name: &str) -> Fixture {
        let dir = Path::new(env!("CARGO_TARGET_TMPDIR"))
            .join("freshness-matrix")
            .join(name);
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("tmp")).unwrap();
        fs::create_dir_all(dir.join("stubs")).unwrap();
        fs::create_dir_all(dir.join("recipe")).unwrap();
        let lock = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let mut restore = EnvRestore(Vec::new());
        for key in ["PATH", "TMPDIR", "GSA_VCS_SKIP_TOLERANCE"] {
            restore.0.push((key, std::env::var_os(key)));
        }
        let old_path = std::env::var_os("PATH").unwrap_or_default();
        let stubs = dir.join("stubs");
        std::env::set_var(
            "PATH",
            format!("{}:{}", stubs.display(), old_path.to_string_lossy()),
        );
        std::env::set_var("TMPDIR", dir.join("tmp"));
        std::env::remove_var("GSA_VCS_SKIP_TOLERANCE");
        Fixture {
            dir: dir.clone(),
            log: dir.join("git.log"),
            stubs,
            recipe: dir.join("recipe"),
            _lock: lock,
            _restore: restore,
        }
    }

    /// Install a `git` stub that logs every invocation and dispatches on the
    /// subcommand (the engine calls `git` only through PATH).
    fn stub_git(&self, handler: &str) {
        let body = format!(
            "echo \"$@\" >> \"{log}\"\ncmd=\"\"; skip=0\nfor a in \"$@\"; do\n  if [ \"$skip\" = 1 ]; then skip=0; continue; fi\n  case \"$a\" in\n    -c|-C) skip=1 ;;\n    -*) ;;\n    *) cmd=\"$a\"; break ;;\n  esac\ndone\n{handler}\nexit 0\n",
            log = self.log.display()
        );
        write_script(&self.stubs.join("git"), &body);
    }

    fn stub_tool(&self, name: &str, handler: &str) {
        write_script(&self.stubs.join(name), handler);
    }

    fn git_calls(&self) -> usize {
        fs::read_to_string(&self.log)
            .map(|s| s.lines().count())
            .unwrap_or(0)
    }

    fn git_log(&self) -> String {
        fs::read_to_string(&self.log).unwrap_or_default()
    }

    fn write(&self, rel: &str, bytes: &[u8]) -> PathBuf {
        let path = self.recipe.join(rel);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        fs::write(&path, bytes).unwrap();
        path
    }
}

fn set_mtime(path: &Path, secs: u64, nanos: u32) {
    let file = fs::OpenOptions::new().write(true).open(path).unwrap();
    let when = UNIX_EPOCH + Duration::new(secs, nanos);
    file.set_times(fs::FileTimes::new().set_modified(when))
        .unwrap();
}

/// Independent sha256 oracle (coreutils) so manifest bindings are checked
/// against something other than the code under test.
fn sha256sum_file(path: &Path) -> String {
    let out = Command::new("sha256sum").arg(path).output().unwrap();
    String::from_utf8_lossy(&out.stdout)
        .split_whitespace()
        .next()
        .unwrap()
        .to_string()
}

fn no_sleeps() -> impl FnMut(Duration) {
    |_: Duration| {}
}

const SRC_ENTRY: &str = "git+https://ex.com/foo.git#branch=main";
/// `source_filename` keeps the `.git` suffix (only checkout lookup strips it).
const SRC_NAME: &str = "foo.git";
const SHA_A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const SHA_B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const SHA_LOCAL: &str = "1111111111111111111111111111111111111111";

/// A recorded recipe + archive fixture: `src/foo` checkout, a known archive,
/// and a `git` stub whose `rev-parse` reports [`SHA_LOCAL`].
fn record_baseline(fx: &Fixture) -> PathBuf {
    fx.stub_git(&format!(
        "case \"$cmd\" in\n  rev-parse) echo '{SHA_LOCAL}' ;;\nesac"
    ));
    fs::create_dir_all(fx.recipe.join("src/foo")).unwrap();
    let archive = fx.write("p1-1.0-1-x86_64.pkg.tar.zst", b"archive bytes v1");
    let recorded = record_vcs_archive_revisions(&fx.recipe, &archive, &[SRC_ENTRY.to_string()])
        .expect("record");
    assert!(recorded.is_some());
    archive
}

// ---------------------------------------------------------------------------
// Pure decision matrix — SkipMode::Skip
// ---------------------------------------------------------------------------

fn source_with(remote: RemoteRevisionState) -> VcsSourceState {
    VcsSourceState {
        key: "a".repeat(64),
        name: "foo".to_string(),
        protocol: Some(VcsKind::Git),
        pinned: false,
        remote,
    }
}

/// A complete, payload-valid, baseline-current, unchanged-ref claim — the
/// happy path every mutation below perturbs.
fn skip_ok_ctx(archives: &[PathBuf]) -> FreshnessContext {
    let mut ctx = FreshnessContext::new("p1", SkipMode::Skip);
    ctx.discovery = Discovery {
        archives: archives.to_vec(),
        missing: Vec::new(),
        established: true,
        version_key: Some("1.0-1".to_string()),
    };
    for archive in archives {
        ctx.payload_ok.insert(archive.clone(), true);
        let mut probe = ArchiveFreshness::new(archive.clone());
        probe.baseline = Some(BaselineState::Ok);
        probe.sources = vec![source_with(RemoteRevisionState::Unchanged)];
        ctx.archives_probe.push(probe);
    }
    ctx
}

#[test]
fn skip_mode_complete_current_set_claims_ok() {
    let archives = vec![PathBuf::from("/w/p1-1.0-1-x86_64.pkg.tar.zst")];
    let ctx = skip_ok_ctx(&archives);
    match decide(&ctx) {
        Verdict::Skip {
            reason,
            waiver_lines,
            archives: claimed,
        } => {
            assert_eq!(reason, REASON_OK);
            assert!(waiver_lines.is_empty(), "no waiver may ride an ok claim");
            assert_eq!(claimed, archives);
        }
        other => panic!("expected Skip, got {other:?}"),
    }
}

#[test]
fn skip_mode_pkgbuild_newer_than_archive_forces_build() {
    let archives = vec![PathBuf::from("/w/p1-1.0-1-x86_64.pkg.tar.zst")];
    let mut ctx = skip_ok_ctx(&archives);
    ctx.pkgbuild_newer_than.push(archives[0].clone());
    let verdict = decide(&ctx);
    assert_eq!(verdict.reason_key(), build_reason::RECIPE_NEWER);
    assert!(
        verdict_reason(&verdict).contains("p1-1.0-1-x86_64.pkg.tar.zst"),
        "the offending archive must be named: {}",
        verdict_reason(&verdict)
    );
}

#[test]
fn skip_mode_partial_split_set_names_missing_output() {
    let archives = vec![PathBuf::from("/w/p1-1.0-1-x86_64.pkg.tar.zst")];
    let mut ctx = skip_ok_ctx(&archives);
    ctx.discovery.missing = vec!["p1-extra".to_string()];
    let verdict = decide(&ctx);
    assert_eq!(verdict.reason_key(), build_reason::PARTIAL_OUTPUT_SET);
    assert!(
        verdict_reason(&verdict).contains("p1-extra"),
        "the missing output must be named: {}",
        verdict_reason(&verdict)
    );
    // Red: the same set WITHOUT the missing name still claims ok.
    ctx.discovery.missing.clear();
    assert_eq!(decide(&ctx).reason_key(), REASON_OK);
}

#[test]
fn skip_mode_unreadable_archive_forces_build_and_doubt_fails_closed() {
    let archives = vec![
        PathBuf::from("/w/p1-1.0-1-x86_64.pkg.tar.zst"),
        PathBuf::from("/w/p1-extra-1.0-1-any.pkg.tar.zst"),
    ];
    let mut ctx = skip_ok_ctx(&archives);
    ctx.payload_ok.insert(archives[1].clone(), false);
    let verdict = decide(&ctx);
    assert_eq!(verdict.reason_key(), build_reason::ARCHIVE_UNREADABLE);
    assert!(verdict_reason(&verdict).contains("p1-extra-1.0-1-any"));

    // Red (fail-closed): an archive that was never probed is NOT readable —
    // a missing map entry must not silently pass.
    let mut ctx = skip_ok_ctx(&archives);
    ctx.payload_ok.remove(&archives[1]);
    assert_eq!(decide(&ctx).reason_key(), build_reason::ARCHIVE_UNREADABLE);
}

#[test]
fn skip_mode_missing_baseline_rebuilds_after_queryable() {
    let archives = vec![PathBuf::from("/w/p1-1.0-1-x86_64.pkg.tar.zst")];
    let mut ctx = skip_ok_ctx(&archives);
    ctx.archives_probe[0].baseline = Some(BaselineState::Missing);
    ctx.archives_probe[0].sources = vec![source_with(RemoteRevisionState::Resolved)];
    let verdict = decide(&ctx);
    assert_eq!(verdict.reason_key(), build_reason::VCS_BASELINE_MISSING);

    // Red ("after queryable"): an unqueryable ref defers instead of
    // rebuilding — the rc-2 class outranks the rebuild-to-record class.
    ctx.archives_probe[0].sources = vec![source_with(RemoteRevisionState::Unverifiable {
        error: "cannot query upstream revision for foo".to_string(),
    })];
    assert_eq!(decide(&ctx).reason_key(), REASON_UPSTREAM_UNVERIFIED);
}

#[test]
fn skip_mode_malformed_baseline_rebuilds() {
    let archives = vec![PathBuf::from("/w/p1-1.0-1-x86_64.pkg.tar.zst")];
    let mut ctx = skip_ok_ctx(&archives);
    ctx.archives_probe[0].baseline = Some(BaselineState::Malformed);
    ctx.archives_probe[0].sources = vec![source_with(RemoteRevisionState::Resolved)];
    assert_eq!(
        decide(&ctx).reason_key(),
        build_reason::VCS_BASELINE_MALFORMED
    );
}

#[test]
fn skip_mode_baseline_identity_mismatch_rebuilds() {
    let archives = vec![PathBuf::from("/w/p1-1.0-1-x86_64.pkg.tar.zst")];
    let mut ctx = skip_ok_ctx(&archives);
    ctx.archives_probe[0].baseline = Some(BaselineState::IdentityMismatch);
    ctx.archives_probe[0].sources = vec![source_with(RemoteRevisionState::Resolved)];
    assert_eq!(
        decide(&ctx).reason_key(),
        build_reason::VCS_BASELINE_IDENTITY
    );
}

#[test]
fn skip_mode_baseline_key_mismatch_rebuilds_naming_the_source() {
    let archives = vec![PathBuf::from("/w/p1-1.0-1-x86_64.pkg.tar.zst")];
    let mut ctx = skip_ok_ctx(&archives);
    ctx.archives_probe[0].baseline = Some(BaselineState::KeyMismatch {
        source: "foo".to_string(),
    });
    ctx.archives_probe[0].sources = vec![source_with(RemoteRevisionState::Resolved)];
    let verdict = decide(&ctx);
    assert_eq!(verdict.reason_key(), build_reason::VCS_BASELINE_KEY);
    assert!(verdict_reason(&verdict).contains("foo"));
}

#[test]
fn skip_mode_moved_within_tolerance_waives_with_line() {
    let archives = vec![PathBuf::from("/w/p1-1.0-1-x86_64.pkg.tar.zst")];
    let mut ctx = skip_ok_ctx(&archives);
    ctx.archives_probe[0].sources = vec![source_with(RemoteRevisionState::Moved {
        distance: Some(2),
    })];
    match decide(&ctx) {
        Verdict::Skip {
            reason,
            waiver_lines,
            ..
        } => {
            assert_eq!(reason, REASON_FRESHNESS_WAIVED);
            assert_eq!(
                waiver_lines,
                vec![
                    "upstream moved 2 commit(s) < tolerance 5 — treating foo as current"
                        .to_string()
                ]
            );
        }
        other => panic!("expected Skip, got {other:?}"),
    }
}

#[test]
fn skip_mode_move_at_or_past_tolerance_rebuilds() {
    let archives = vec![PathBuf::from("/w/p1-1.0-1-x86_64.pkg.tar.zst")];
    // Distance exactly AT the tolerance is not strictly below it.
    let mut ctx = skip_ok_ctx(&archives);
    ctx.archives_probe[0].sources = vec![source_with(RemoteRevisionState::Moved {
        distance: Some(5),
    })];
    assert_eq!(decide(&ctx).reason_key(), build_reason::VCS_REF_MOVED);
    // Past the tolerance.
    ctx.archives_probe[0].sources = vec![source_with(RemoteRevisionState::Moved {
        distance: Some(6),
    })];
    assert_eq!(decide(&ctx).reason_key(), build_reason::VCS_REF_MOVED);
}

#[test]
fn skip_mode_unmeasurable_move_never_waives() {
    let archives = vec![PathBuf::from("/w/p1-1.0-1-x86_64.pkg.tar.zst")];
    let mut ctx = skip_ok_ctx(&archives);
    // Unmeasurable means ">= the window", never a small move — no waiver.
    ctx.archives_probe[0].sources =
        vec![source_with(RemoteRevisionState::Moved { distance: None })];
    assert_eq!(decide(&ctx).reason_key(), build_reason::VCS_REF_MOVED);
    // Red: distance 0 is not a positive measured distance either.
    ctx.archives_probe[0].sources = vec![source_with(RemoteRevisionState::Moved {
        distance: Some(0),
    })];
    assert_eq!(decide(&ctx).reason_key(), build_reason::VCS_REF_MOVED);
}

#[test]
fn skip_mode_abi_provider_waives_any_measured_distance() {
    let archives = vec![PathBuf::from("/w/p1-1.0-1-x86_64.pkg.tar.zst")];
    let mut ctx = skip_ok_ctx(&archives);
    ctx.abi_provider = true;
    ctx.archives_probe[0].sources = vec![source_with(RemoteRevisionState::Moved {
        distance: Some(987),
    })];
    match decide(&ctx) {
        Verdict::Skip {
            reason,
            waiver_lines,
            ..
        } => {
            assert_eq!(reason, REASON_ABI_PROVIDER_WAIVED);
            assert_eq!(
                waiver_lines,
                vec![
                    "upstream moved 987 commit(s) — p1 is an ABI provider; freshness waived (rebuild only on measured skew or an explicit build)"
                        .to_string()
                ]
            );
        }
        other => panic!("expected Skip, got {other:?}"),
    }
}

#[test]
fn skip_mode_abi_provider_unmeasurable_distance_never_invents_a_count() {
    let archives = vec![PathBuf::from("/w/p1-1.0-1-x86_64.pkg.tar.zst")];
    let mut ctx = skip_ok_ctx(&archives);
    ctx.abi_provider = true;
    ctx.archives_probe[0].sources =
        vec![source_with(RemoteRevisionState::Moved { distance: None })];
    match decide(&ctx) {
        Verdict::Skip {
            reason,
            waiver_lines,
            ..
        } => {
            assert_eq!(reason, REASON_ABI_PROVIDER_WAIVED);
            assert_eq!(
                waiver_lines,
                vec![
                    "upstream moved past the measurement window (64 commits) — p1 is an ABI provider; freshness waived (rebuild only on measured skew or an explicit build)"
                        .to_string()
                ]
            );
            assert!(
                !waiver_lines[0].contains("commit(s)"),
                "an unmeasurable move must not invent a count"
            );
        }
        other => panic!("expected Skip, got {other:?}"),
    }
}

#[test]
fn skip_mode_abi_provider_waives_non_git_moves_without_a_count() {
    let archives = vec![PathBuf::from("/w/p1-1.0-1-x86_64.pkg.tar.zst")];
    let mut ctx = skip_ok_ctx(&archives);
    ctx.abi_provider = true;
    let mut src = source_with(RemoteRevisionState::Moved { distance: None });
    src.protocol = Some(VcsKind::Svn);
    ctx.archives_probe[0].sources = vec![src];
    match decide(&ctx) {
        Verdict::Skip { waiver_lines, .. } => {
            assert!(waiver_lines[0].starts_with("upstream revision moved — p1 is an ABI provider"));
        }
        other => panic!("expected Skip, got {other:?}"),
    }
}

#[test]
fn skip_mode_pinned_mismatch_rebuilds_even_for_abi_provider() {
    let archives = vec![PathBuf::from("/w/p1-1.0-1-x86_64.pkg.tar.zst")];
    let mut ctx = skip_ok_ctx(&archives);
    ctx.abi_provider = true;
    let mut src = source_with(RemoteRevisionState::PinnedMismatch);
    src.pinned = true;
    ctx.archives_probe[0].sources = vec![src];
    // A mismatched pinned commit is local inconsistency, not movement: the
    // ABI waiver is purely the 0/1 boundary and never reaches it.
    assert_eq!(
        decide(&ctx).reason_key(),
        build_reason::VCS_REF_PINNED_MISMATCH
    );
}

#[test]
fn skip_mode_unverifiable_defers_only_when_chain_absorbs_the_wait() {
    let archives = vec![PathBuf::from("/w/p1-1.0-1-x86_64.pkg.tar.zst")];
    let mut ctx = skip_ok_ctx(&archives);
    ctx.archives_probe[0].sources = vec![source_with(RemoteRevisionState::Unverifiable {
        error: "cannot query upstream revision for foo".to_string(),
    })];
    assert_eq!(decide(&ctx).reason_key(), REASON_UPSTREAM_UNVERIFIED);
    // Consumers cannot wait → fall back to a normal build attempt, never fail.
    ctx.absorb_wait = false;
    assert_eq!(decide(&ctx).reason_key(), build_reason::VCS_UNVERIFIABLE);
}

#[test]
fn pending_abi_repair_outranks_every_freshness_claim() {
    let archives = vec![PathBuf::from("/w/p1-1.0-1-x86_64.pkg.tar.zst")];
    let mut ctx = skip_ok_ctx(&archives);
    ctx.pending_abi_repair = true;
    assert_eq!(decide(&ctx).reason_key(), build_reason::ABI_REPAIR_PENDING);
    // Red: even the --skip-built claim yields to a pending repair.
    let mut ctx = skip_ok_ctx(&archives);
    ctx.skip_mode = SkipMode::SkipBuilt;
    ctx.pending_abi_repair = true;
    assert_eq!(decide(&ctx).reason_key(), build_reason::ABI_REPAIR_PENDING);
}

#[test]
fn discovery_unestablished_and_nothing_built_name_their_reasons() {
    let archives = vec![PathBuf::from("/w/p1-1.0-1-x86_64.pkg.tar.zst")];
    let mut ctx = skip_ok_ctx(&archives);
    ctx.discovery.established = false;
    assert_eq!(
        decide(&ctx).reason_key(),
        build_reason::DISCOVERY_UNESTABLISHED
    );
    let mut ctx = skip_ok_ctx(&archives);
    ctx.discovery.archives.clear();
    ctx.discovery.missing = vec!["p1".to_string()];
    assert_eq!(decide(&ctx).reason_key(), build_reason::NOTHING_BUILT);
}

// ---------------------------------------------------------------------------
// Pure decision matrix — SkipMode::SkipBuilt
// ---------------------------------------------------------------------------

#[test]
fn skip_built_claims_newest_complete_set_at_any_version() {
    // The claimed set is at 2.0-1 while the recipe's committed key is 1.0-1:
    // "built remains built" is a BUILD claim, never the committed pkgver.
    let archives = vec![
        PathBuf::from("/w/p1-2.0-1-x86_64.pkg.tar.zst"),
        PathBuf::from("/w/p1-extra-2.0-1-any.pkg.tar.zst"),
    ];
    let mut ctx = skip_ok_ctx(&archives);
    ctx.skip_mode = SkipMode::SkipBuilt;
    ctx.discovery.version_key = Some("2.0-1".to_string());
    ctx.archives_probe.clear(); // freshness analysis is off — no probes exist
    match decide(&ctx) {
        Verdict::Skip {
            reason,
            waiver_lines,
            archives: claimed,
        } => {
            assert_eq!(reason, REASON_SKIP_BUILT);
            assert!(waiver_lines.is_empty(), "--skip-built has nothing to waive");
            assert_eq!(claimed, archives);
        }
        other => panic!("expected Skip, got {other:?}"),
    }
}

#[test]
fn skip_built_recipe_changed_since_the_set_rebuilds() {
    let archives = vec![PathBuf::from("/w/p1-2.0-1-x86_64.pkg.tar.zst")];
    let mut ctx = skip_ok_ctx(&archives);
    ctx.skip_mode = SkipMode::SkipBuilt;
    ctx.recipe_changed_since.push(archives[0].clone());
    let verdict = decide(&ctx);
    assert_eq!(verdict.reason_key(), build_reason::RECIPE_CHANGED);
    assert!(verdict_reason(&verdict).contains("p1-2.0-1-x86_64.pkg.tar.zst"));
}

// ---------------------------------------------------------------------------
// IO: discovery, payload probe, recipe-change gate
// ---------------------------------------------------------------------------

fn verdict_reason(verdict: &Verdict) -> &str {
    match verdict {
        Verdict::Build { reason } => reason,
        other => panic!("expected Build, got {other:?}"),
    }
}

#[test]
fn skip_built_verdict_touches_no_network_probe_at_all() {
    let fx = Fixture::new("skip_built_no_network");
    // A poison git stub: loud failure if anything invokes it. The context
    // carries the precomputed recipe-change gate, so nothing here may fork
    // git — least of all a network probe.
    fx.stub_git("echo 'git must not be called' >&2; exit 99\n");
    fx.stub_tool("pacman", "exit 0\n");
    fx.write(
        ".SRCINFO",
        b"pkgbase = p1\npkgver = 1.0\npkgrel = 1\npkgname = p1\n",
    );
    // Newer set at a version the committed pkgver does not name.
    let older = fx.write("p1-1.0-1-x86_64.pkg.tar.zst", b"older");
    set_mtime(&older, 100, 0);
    let newer = fx.write("p1-2.0-1-x86_64.pkg.tar.zst", b"newer");
    set_mtime(&newer, 200, 0);

    let discovery = discover_newest_complete_set(&fx.recipe);
    assert_eq!(discovery.status(), DiscoveryStatus::Complete);
    assert_eq!(discovery.version_key.as_deref(), Some("2.0-1"));
    assert_eq!(discovery.archives, vec![newer.clone()]);

    let mut ctx = FreshnessContext::new("p1", SkipMode::SkipBuilt);
    ctx.discovery = discovery;
    for archive in &ctx.discovery.archives.clone() {
        ctx.payload_ok
            .insert(archive.clone(), archive_payload_ok(archive));
    }
    match decide(&ctx) {
        Verdict::Skip { reason, .. } => assert_eq!(reason, REASON_SKIP_BUILT),
        other => panic!("expected Skip, got {other:?}"),
    }
    assert_eq!(
        fx.git_calls(),
        0,
        "--skip-built must not invoke git at all: {}",
        fx.git_log()
    );
}

#[test]
fn discovery_assigns_longest_prefix_and_groups_by_pv_pr_key() {
    let fx = Fixture::new("discovery_grouping");
    fx.write(
        ".SRCINFO",
        b"pkgbase = p1\npkgver = 1.0\npkgrel = 1\npkgname = p1\npkgname = p1-extra\n",
    );
    let old_main = fx.write("p1-1.0-1-x86_64.pkg.tar.zst", b"old main");
    set_mtime(&old_main, 100, 0);
    let old_extra = fx.write("p1-extra-1.0-1-any.pkg.tar.zst", b"old extra");
    set_mtime(&old_extra, 100, 0);
    // A same-version ARCH-flavour leftover rides along instead of displacing.
    let old_flavour = fx.write("p1-1.0-1-any.pkg.tar.zst", b"old flavour");
    set_mtime(&old_flavour, 50, 0);
    // Newer but partial key: must never let the older complete set cover for it.
    let new_main = fx.write("p1-2.0-1-x86_64.pkg.tar.zst", b"new main");
    set_mtime(&new_main, 200, 0);

    // --skip: the CURRENT version key only; the flavour leftover rides along.
    let current = discover_current_set(&fx.recipe);
    assert_eq!(current.status(), DiscoveryStatus::Complete);
    assert_eq!(current.version_key.as_deref(), Some("1.0-1"));
    assert_eq!(
        current.archives,
        vec![old_flavour.clone(), old_main.clone(), old_extra.clone()]
            .into_iter()
            .collect::<std::collections::BTreeSet<_>>()
            .into_iter()
            .collect::<Vec<_>>()
    );

    // --skip-built: the newest key owns the claim and reports its gaps.
    let newest = discover_newest_complete_set(&fx.recipe);
    assert_eq!(newest.status(), DiscoveryStatus::Partial);
    assert_eq!(newest.version_key.as_deref(), Some("2.0-1"));
    assert_eq!(newest.archives, vec![new_main.clone()]);
    assert_eq!(newest.missing, vec!["p1-extra".to_string()]);

    // Red: complete the new key and the claim flips to Complete.
    let new_extra = fx.write("p1-extra-2.0-1-any.pkg.tar.zst", b"new extra");
    set_mtime(&new_extra, 200, 1);
    let newest = discover_newest_complete_set(&fx.recipe);
    assert_eq!(newest.status(), DiscoveryStatus::Complete);
    assert_eq!(newest.missing, Vec::<String>::new());
    assert_eq!(newest.archives, vec![new_main, new_extra]);
}

#[test]
fn discovery_never_counts_a_longer_output_as_a_shorter_one() {
    let fx = Fixture::new("discovery_longest_prefix");
    fx.write(
        ".SRCINFO",
        b"pkgbase = p1\npkgver = 1.0\npkgrel = 1\npkgname = p1\npkgname = p1-extra\n",
    );
    let extra = fx.write("p1-extra-1.0-1-any.pkg.tar.zst", b"extra only");
    set_mtime(&extra, 100, 0);
    // `p1-extra-…` is prefixed by `p1-` too: only the LONGEST name may own it,
    // so output `p1` stays uncovered (the fish split-set guard).
    let newest = discover_newest_complete_set(&fx.recipe);
    assert_eq!(newest.status(), DiscoveryStatus::Partial);
    assert_eq!(newest.archives, vec![extra]);
    assert_eq!(newest.missing, vec!["p1".to_string()]);
}

#[test]
fn payload_probe_runs_pacman_through_path() {
    let fx = Fixture::new("payload_probe");
    let archive = fx.write("p1-1.0-1-x86_64.pkg.tar.zst", b"payload");
    fx.stub_tool("pacman", "echo \"$@\" >> \"$PACMAN_LOG\"; exit 0\n");
    std::env::set_var("PACMAN_LOG", fx.dir.join("pacman.log"));
    assert!(archive_payload_ok(&archive));
    fx.stub_tool("pacman", "exit 1\n");
    assert!(!archive_payload_ok(&archive));
    std::env::remove_var("PACMAN_LOG");
}

#[test]
fn recipe_changed_since_build_gits_commit_time_with_second_ceil() {
    let fx = Fixture::new("recipe_change_git");
    let pkgbuild = fx.write("PKGBUILD", b"pkgname=p1\n");
    let archive = fx.write("p1-1.0-1-x86_64.pkg.tar.zst", b"archive");
    // Archive mtime 1000.5s → ceil boundary is 1001; a commit AT the ceil
    // may postdate the archive, and that doubt rebuilds.
    set_mtime(&archive, 1000, 500_000_000);
    fx.stub_git("case \"$cmd\" in\n  log) echo 1001 ;;\nesac");
    assert!(recipe_changed_since_build(&fx.recipe, &archive));
    fx.stub_git("case \"$cmd\" in\n  log) echo 1000 ;;\nesac");
    assert!(!recipe_changed_since_build(&fx.recipe, &archive));
    // Whole-second mtime: the boundary is the second itself.
    set_mtime(&archive, 1000, 0);
    fx.stub_git("case \"$cmd\" in\n  log) echo 1000 ;;\nesac");
    assert!(recipe_changed_since_build(&fx.recipe, &archive));
    fx.stub_git("case \"$cmd\" in\n  log) echo 999 ;;\nesac");
    assert!(!recipe_changed_since_build(&fx.recipe, &archive));
    set_mtime(&pkgbuild, 5000, 0);
}

#[test]
fn recipe_changed_since_build_falls_back_to_mtime_without_git() {
    let fx = Fixture::new("recipe_change_mtime");
    let pkgbuild = fx.write("PKGBUILD", b"pkgname=p1\n");
    let archive = fx.write("p1-1.0-1-x86_64.pkg.tar.zst", b"archive");
    fx.stub_git("exit 128\n"); // no git metadata at all
    set_mtime(&pkgbuild, 2000, 0);
    set_mtime(&archive, 1000, 0);
    assert!(recipe_changed_since_build(&fx.recipe, &archive));
    // PKGBUILD mtime churn alone: older or equal mtimes never rebuild.
    set_mtime(&pkgbuild, 500, 0);
    assert!(!recipe_changed_since_build(&fx.recipe, &archive));
    set_mtime(&pkgbuild, 1000, 0);
    assert!(!recipe_changed_since_build(&fx.recipe, &archive));
}

// ---------------------------------------------------------------------------
// Baseline manifest format 2: round-trip, shape refusals, recording
// ---------------------------------------------------------------------------

fn sample_baseline() -> VcsBaseline {
    VcsBaseline {
        archive_sha256: "ab".repeat(32),
        archive_size: 42,
        rows: vec![VcsBaselineRow {
            key: "cd".repeat(32),
            protocol: VcsKind::Git,
            revision: SHA_A.to_string(),
        }],
    }
}

#[test]
fn baseline_render_parse_round_trips_and_shape_mutations_fail() {
    let baseline = sample_baseline();
    let text = baseline.render();
    assert_eq!(VcsBaseline::parse(&text).unwrap(), baseline);

    // Red: every shape mutation must be a named refusal, not a half-trusted
    // parse (each of these would silently bless or silently rebuild wrongly).
    let mutations: Vec<(&str, String)> = vec![
        (
            "header",
            text.replace("gsa-vcs-revisions\t2", "gsa-vcs-revisions\t1"),
        ),
        (
            "uppercase sha",
            text.replace(
                &baseline.archive_sha256,
                &baseline.archive_sha256.to_uppercase(),
            ),
        ),
        ("short sha", text.replace(&baseline.archive_sha256, "abcd")),
        ("non-numeric size", text.replace("\t42", "\t42x")),
        ("bad protocol", text.replace("\tgit\t", "\tcvs\t")),
        ("two-field row", {
            let head: String = text.lines().take(2).map(|l| format!("{l}\n")).collect();
            format!("{head}{}\tgit\n", baseline.rows[0].key)
        }),
        ("empty revision", text.replace(SHA_A, "")),
    ];
    for (name, mutated) in mutations {
        assert!(
            matches!(
                VcsBaseline::parse(&mutated),
                Err(FreshnessError::Baseline(_))
            ),
            "mutation '{name}' must refuse to parse: {mutated:?}"
        );
    }
}

#[test]
fn record_binds_baseline_to_exact_archive_bytes_atomically() {
    let fx = Fixture::new("record_happy");
    let archive = record_baseline(&fx);
    let manifest = manifest_path(&archive);
    let text = fs::read_to_string(&manifest).unwrap();
    let mut lines = text.lines();
    assert_eq!(lines.next(), Some(MANIFEST_MAGIC));
    let expected_identity = format!(
        "archive\t{}\t{}",
        sha256sum_file(&archive),
        b"archive bytes v1".len()
    );
    assert_eq!(lines.next(), Some(expected_identity.as_str()));
    let row = lines.next().unwrap();
    let fields: Vec<&str> = row.split('\t').collect();
    assert_eq!(fields[0], vcs_source_key(SRC_ENTRY));
    assert_eq!(fields[1], "git");
    assert_eq!(fields[2], SHA_LOCAL);
    assert_eq!(lines.next(), None, "exactly one row per distinct source");
    // Atomic publish leaves no temporaries beside the manifest.
    let leftovers: Vec<_> = fs::read_dir(&fx.recipe)
        .unwrap()
        .flatten()
        .filter(|e| e.file_name().to_string_lossy().contains(".tmp."))
        .collect();
    assert!(leftovers.is_empty(), "tmp files left behind: {leftovers:?}");

    // Round-trip through the probe: bound bytes + matching ref = current.
    fx.stub_git(&format!(
        "case \"$cmd\" in\n  rev-parse) echo '{SHA_LOCAL}' ;;\n  ls-remote) printf '%s\\t%s\\n' '{SHA_LOCAL}' 'refs/heads/main' ;;\nesac"
    ));
    let probe = probe_archive(
        &archive,
        &[SRC_ENTRY.to_string()],
        &ProbeOptions {
            tolerance: DEFAULT_VCS_SKIP_TOLERANCE,
            abi_provider: false,
        },
        &mut no_sleeps(),
    );
    assert_eq!(probe.baseline, Some(BaselineState::Ok));
    assert_eq!(probe.sources[0].remote, RemoteRevisionState::Unchanged);
}

#[test]
fn record_refuses_when_archive_cannot_be_fingerprinted() {
    let fx = Fixture::new("record_no_fingerprint");
    fx.stub_git(&format!(
        "case \"$cmd\" in\n  rev-parse) echo '{SHA_LOCAL}' ;;\nesac"
    ));
    fs::create_dir_all(fx.recipe.join("src/foo")).unwrap();
    let archive = fx.recipe.join("p1-1.0-1-x86_64.pkg.tar.zst"); // never written
    let err = record_vcs_archive_revisions(&fx.recipe, &archive, &[SRC_ENTRY.to_string()])
        .expect_err("an unfingerprintable archive must never be blessed");
    match &err {
        FreshnessError::Record(message) => {
            assert!(
                message.contains("cannot fingerprint the built archive"),
                "{message}"
            )
        }
        other => panic!("expected Record refusal, got {other:?}"),
    }
    assert!(
        !manifest_path(&archive).exists(),
        "a refused record must leave no baseline behind"
    );
}

#[test]
fn record_without_vcs_sources_removes_stale_manifest() {
    let fx = Fixture::new("record_no_vcs");
    let archive = fx.write("p1-1.0-1-x86_64.pkg.tar.zst", b"plain archive");
    let manifest = manifest_path(&archive);
    fs::write(&manifest, "stale").unwrap();
    let recorded = record_vcs_archive_revisions(
        &fx.recipe,
        &archive,
        &["https://ex.com/plain.tar".to_string()],
    )
    .unwrap();
    assert!(recorded.is_none());
    assert!(!manifest.exists(), "a non-VCS recipe must keep no baseline");
}

// ---------------------------------------------------------------------------
// IO probe → decide: the end-to-end freshness claims
// ---------------------------------------------------------------------------

#[test]
fn probe_tampered_manifest_sha_reports_identity_mismatch() {
    let fx = Fixture::new("probe_tampered_sha");
    let archive = record_baseline(&fx);
    let manifest = manifest_path(&archive);
    let text = fs::read_to_string(&manifest).unwrap();
    // Tamper the sha only: shape stays valid, identity no longer binds.
    let tampered = text.replace(&sha256sum_file(&archive), &"0".repeat(64));
    fs::write(&manifest, &tampered).unwrap();
    fx.stub_git(&format!(
        "case \"$cmd\" in\n  rev-parse) echo '{SHA_LOCAL}' ;;\n  ls-remote) printf '%s\\t%s\\n' '{SHA_LOCAL}' 'refs/heads/main' ;;\nesac"
    ));
    let probe = probe_archive(
        &archive,
        &[SRC_ENTRY.to_string()],
        &ProbeOptions {
            tolerance: DEFAULT_VCS_SKIP_TOLERANCE,
            abi_provider: false,
        },
        &mut no_sleeps(),
    );
    assert_eq!(probe.baseline, Some(BaselineState::IdentityMismatch));
    let ctx = ctx_from_probe(&archive, probe);
    let verdict = decide(&ctx);
    assert_eq!(verdict.reason_key(), build_reason::VCS_BASELINE_IDENTITY);
}

#[test]
fn probe_replaced_archive_bytes_reports_identity_mismatch() {
    let fx = Fixture::new("probe_replaced_bytes");
    let archive = record_baseline(&fx);
    // Same size, different bytes: only the checksum can reject this one.
    fs::write(&archive, b"archive bytes V2").unwrap();
    fx.stub_git(&format!(
        "case \"$cmd\" in\n  rev-parse) echo '{SHA_LOCAL}' ;;\n  ls-remote) printf '%s\\t%s\\n' '{SHA_LOCAL}' 'refs/heads/main' ;;\nesac"
    ));
    let probe = probe_archive(
        &archive,
        &[SRC_ENTRY.to_string()],
        &ProbeOptions {
            tolerance: DEFAULT_VCS_SKIP_TOLERANCE,
            abi_provider: false,
        },
        &mut no_sleeps(),
    );
    assert_eq!(probe.baseline, Some(BaselineState::IdentityMismatch));
}

#[test]
fn probe_missing_baseline_rebuilds_only_after_refs_are_queryable() {
    let fx = Fixture::new("probe_missing_baseline");
    let archive = record_baseline(&fx);
    fs::remove_file(manifest_path(&archive)).unwrap();
    // Queryable ref: rebuild once to record a baseline.
    fx.stub_git(&format!(
        "case \"$cmd\" in\n  ls-remote) printf '%s\\t%s\\n' '{SHA_A}' 'refs/heads/main' ;;\nesac"
    ));
    let probe = probe_archive(
        &archive,
        &[SRC_ENTRY.to_string()],
        &ProbeOptions {
            tolerance: DEFAULT_VCS_SKIP_TOLERANCE,
            abi_provider: false,
        },
        &mut no_sleeps(),
    );
    assert_eq!(probe.baseline, Some(BaselineState::Missing));
    assert_eq!(probe.sources[0].remote, RemoteRevisionState::Resolved);
    let ctx = ctx_from_probe(&archive, probe);
    assert_eq!(
        decide(&ctx).reason_key(),
        build_reason::VCS_BASELINE_MISSING
    );

    // Red ("only after"): an unqueryable ref defers instead of rebuilding.
    fx.stub_git("case \"$cmd\" in\n  ls-remote) exit 128 ;;\nesac");
    let mut sleeps = Vec::new();
    let probe = probe_archive(
        &archive,
        &[SRC_ENTRY.to_string()],
        &ProbeOptions {
            tolerance: DEFAULT_VCS_SKIP_TOLERANCE,
            abi_provider: false,
        },
        &mut |d| sleeps.push(d),
    );
    assert_eq!(probe.baseline, Some(BaselineState::Missing));
    assert!(matches!(
        probe.sources[0].remote,
        RemoteRevisionState::Unverifiable { .. }
    ));
    assert_eq!(
        sleeps,
        vec![
            Duration::from_secs(2),
            Duration::from_secs(5),
            Duration::from_secs(10),
            Duration::from_secs(20),
            Duration::from_secs(40)
        ],
        "the unverifiable class must walk the full retry budget"
    );
    let ctx = ctx_from_probe(&archive, probe);
    assert_eq!(decide(&ctx).reason_key(), REASON_UPSTREAM_UNVERIFIED);
}

#[test]
fn probe_moved_ref_waives_within_tolerance_end_to_end() {
    let fx = Fixture::new("probe_moved_waived");
    let archive = record_baseline(&fx);
    fx.stub_git(&format!(
        "case \"$cmd\" in\n  ls-remote) printf '%s\\t%s\\n' '{SHA_B}' 'refs/heads/main' ;;\n  init) exit 0 ;;\n  fetch) exit 0 ;;\n  rev-list) echo 2 ;;\nesac"
    ));
    let probe = probe_archive(
        &archive,
        &[SRC_ENTRY.to_string()],
        &ProbeOptions {
            tolerance: DEFAULT_VCS_SKIP_TOLERANCE,
            abi_provider: false,
        },
        &mut no_sleeps(),
    );
    assert_eq!(
        probe.sources[0].remote,
        RemoteRevisionState::Moved { distance: Some(2) }
    );
    let ctx = ctx_from_probe(&archive, probe);
    match decide(&ctx) {
        Verdict::Skip {
            reason,
            waiver_lines,
            ..
        } => {
            assert_eq!(reason, REASON_FRESHNESS_WAIVED);
            assert_eq!(
                waiver_lines,
                vec![format!(
                    "upstream moved 2 commit(s) < tolerance 5 — treating {SRC_NAME} as current"
                )]
            );
        }
        other => panic!("expected Skip, got {other:?}"),
    }

    // Red: the same probe measuring distance 5 (AT the tolerance) rebuilds.
    fx.stub_git(&format!(
        "case \"$cmd\" in\n  ls-remote) printf '%s\\t%s\\n' '{SHA_B}' 'refs/heads/main' ;;\n  init) exit 0 ;;\n  fetch) exit 0 ;;\n  rev-list) echo 5 ;;\nesac"
    ));
    let probe = probe_archive(
        &archive,
        &[SRC_ENTRY.to_string()],
        &ProbeOptions {
            tolerance: DEFAULT_VCS_SKIP_TOLERANCE,
            abi_provider: false,
        },
        &mut no_sleeps(),
    );
    assert_eq!(
        probe.sources[0].remote,
        RemoteRevisionState::Moved { distance: Some(5) }
    );
    let ctx = ctx_from_probe(&archive, probe);
    assert_eq!(decide(&ctx).reason_key(), build_reason::VCS_REF_MOVED);
}

#[test]
fn probe_key_mismatch_names_the_source_and_rebuilds() {
    let fx = Fixture::new("probe_key_mismatch");
    let archive = record_baseline(&fx);
    let manifest = manifest_path(&archive);
    let text = fs::read_to_string(&manifest).unwrap();
    // Rewrite the row key: the baseline belongs to a different source now.
    let tampered = text.replace(&vcs_source_key(SRC_ENTRY), &"9".repeat(64));
    fs::write(&manifest, &tampered).unwrap();
    fx.stub_git(&format!(
        "case \"$cmd\" in\n  ls-remote) printf '%s\\t%s\\n' '{SHA_LOCAL}' 'refs/heads/main' ;;\nesac"
    ));
    let probe = probe_archive(
        &archive,
        &[SRC_ENTRY.to_string()],
        &ProbeOptions {
            tolerance: DEFAULT_VCS_SKIP_TOLERANCE,
            abi_provider: false,
        },
        &mut no_sleeps(),
    );
    assert_eq!(
        probe.baseline,
        Some(BaselineState::KeyMismatch {
            source: SRC_NAME.to_string()
        })
    );
    let ctx = ctx_from_probe(&archive, probe);
    let verdict = decide(&ctx);
    assert_eq!(verdict.reason_key(), build_reason::VCS_BASELINE_KEY);
    assert!(verdict_reason(&verdict).contains("foo"));
}

#[test]
fn probe_pinned_commit_mismatch_is_local_inconsistency_without_a_query() {
    let fx = Fixture::new("probe_pinned");
    let pinned_entry = "git+https://ex.com/foo.git#commit=abc1234";
    fx.stub_git(&format!(
        "case \"$cmd\" in\n  rev-parse) echo '{SHA_LOCAL}' ;;\nesac"
    ));
    fs::create_dir_all(fx.recipe.join("src/foo")).unwrap();
    let archive = fx.write("p1-1.0-1-x86_64.pkg.tar.zst", b"pinned archive");
    record_vcs_archive_revisions(&fx.recipe, &archive, &[pinned_entry.to_string()]).unwrap();
    let calls_after_record = fx.git_calls();

    let opts = ProbeOptions {
        tolerance: DEFAULT_VCS_SKIP_TOLERANCE,
        abi_provider: true,
    };
    // Recorded SHA_LOCAL does not start with the pin → mismatch, and even an
    // ABI provider rebuilds (the waiver is purely the 0/1 movement boundary).
    let probe = probe_archive(
        &archive,
        &[pinned_entry.to_string()],
        &opts,
        &mut no_sleeps(),
    );
    assert_eq!(probe.sources[0].remote, RemoteRevisionState::PinnedMismatch);
    assert_eq!(
        fx.git_calls(),
        calls_after_record,
        "a pinned commit is immutable: resolving it must not query upstream"
    );
    let mut ctx = ctx_from_probe(&archive, probe);
    ctx.abi_provider = true;
    assert_eq!(
        decide(&ctx).reason_key(),
        build_reason::VCS_REF_PINNED_MISMATCH
    );

    // Positive: a pin that PREFIXES the recorded revision is current.
    fx.stub_git(&format!(
        "case \"$cmd\" in\n  rev-parse) echo 'abc1234fffffffffffffffffffffffffffffffffff' ;;\nesac"
    ));
    let archive2 = fx.write("p1-2.0-1-x86_64.pkg.tar.zst", b"pinned archive two");
    record_vcs_archive_revisions(&fx.recipe, &archive2, &[pinned_entry.to_string()]).unwrap();
    let probe = probe_archive(
        &archive2,
        &[pinned_entry.to_string()],
        &opts,
        &mut no_sleeps(),
    );
    assert_eq!(probe.sources[0].remote, RemoteRevisionState::Unchanged);
}

fn ctx_from_probe(archive: &Path, probe: ArchiveFreshness) -> FreshnessContext {
    let mut ctx = FreshnessContext::new("p1", SkipMode::Skip);
    ctx.discovery = Discovery {
        archives: vec![archive.to_path_buf()],
        missing: Vec::new(),
        established: true,
        version_key: Some("1.0-1".to_string()),
    };
    ctx.payload_ok.insert(archive.to_path_buf(), true);
    ctx.archives_probe = vec![probe];
    ctx
}

// ---------------------------------------------------------------------------
// Transport discipline: permanent answers vs retryable failures
// ---------------------------------------------------------------------------

#[test]
fn transport_exit_zero_answers_after_one_invocation() {
    let fx = Fixture::new("transport_ok");
    fx.stub_git("printf '%s\\t%s\\n' 'abcd' 'refs/heads/main'; exit 0\n");
    let mut sleeps = Vec::new();
    let outcome = git_ls_remote(
        &[
            "--exit-code".to_string(),
            "https://ex.com/foo.git".to_string(),
        ],
        &mut |d| sleeps.push(d),
    );
    assert_eq!(
        outcome,
        LsRemoteOutcome::Answered(vec![format!("abcd\trefs/heads/main")])
    );
    assert_eq!(fx.git_calls(), 1);
    assert!(sleeps.is_empty(), "a completed answer must never retry");
}

#[test]
fn transport_exit_two_is_a_permanent_answer_never_retried() {
    let fx = Fixture::new("transport_no_such_ref");
    fx.stub_git("exit 2\n");
    let mut sleeps = Vec::new();
    let outcome = git_ls_remote(
        &[
            "--exit-code".to_string(),
            "https://ex.com/foo.git".to_string(),
        ],
        &mut |d| sleeps.push(d),
    );
    assert_eq!(outcome, LsRemoteOutcome::NoSuchRef);
    assert_eq!(
        fx.git_calls(),
        1,
        "a clean 'no such ref' is an answer, not a transport failure"
    );
    assert!(sleeps.is_empty());
}

#[test]
fn transport_failures_retry_exactly_six_times_with_bounded_backoff() {
    let fx = Fixture::new("transport_exhausted");
    fx.stub_git("exit 128\n");
    let mut sleeps = Vec::new();
    let outcome = git_ls_remote(
        &[
            "--exit-code".to_string(),
            "https://ex.com/foo.git".to_string(),
        ],
        &mut |d| sleeps.push(d),
    );
    assert_eq!(outcome, LsRemoteOutcome::TransportExhausted { status: 128 });
    assert_eq!(fx.git_calls(), 6, "log: {}", fx.git_log());
    assert_eq!(
        sleeps,
        vec![
            Duration::from_secs(2),
            Duration::from_secs(5),
            Duration::from_secs(10),
            Duration::from_secs(20),
            Duration::from_secs(40)
        ],
        "the sleeper must receive 2/5/10/20/40 — and nothing here actually slept"
    );
}

// ---------------------------------------------------------------------------
// Advance-distance measurement
// ---------------------------------------------------------------------------

#[test]
fn advance_distance_measures_and_fails_closed() {
    let fx = Fixture::new("advance_distance");
    let mut sleeps = Vec::new();
    let scratch_root = fx.dir.join("tmp");

    // Happy path: measured distance, no sleeps, scratch cleaned up.
    fx.stub_git(
        "case \"$cmd\" in\n  init) exit 0 ;;\n  fetch) exit 0 ;;\n  rev-list) echo 2 ;;\nesac",
    );
    let distance = vcs_git_advance_distance(
        "https://ex.com/foo.git",
        "refs/heads/main",
        SHA_A,
        SHA_B,
        6,
        &mut |d| sleeps.push(d),
    );
    assert_eq!(distance, Some(2));
    assert!(sleeps.is_empty());
    assert_eq!(
        fs::read_dir(&scratch_root).unwrap().count(),
        0,
        "the scratch repo must be cleaned up"
    );

    // A failing rev-list means ">= the window", never a small move.
    fx.stub_git(
        "case \"$cmd\" in\n  init) exit 0 ;;\n  fetch) exit 0 ;;\n  rev-list) exit 1 ;;\nesac",
    );
    assert_eq!(
        vcs_git_advance_distance(
            "https://ex.com/foo.git",
            "refs/heads/main",
            SHA_A,
            SHA_B,
            6,
            &mut |d| sleeps.push(d),
        ),
        None
    );

    // A fetch that never succeeds is unmeasurable too (3 attempts, 2/5 s).
    sleeps.clear();
    fx.stub_git("case \"$cmd\" in\n  init) exit 0 ;;\n  fetch) exit 1 ;;\nesac");
    assert_eq!(
        vcs_git_advance_distance(
            "https://ex.com/foo.git",
            "refs/heads/main",
            SHA_A,
            SHA_B,
            6,
            &mut |d| sleeps.push(d),
        ),
        None
    );
    assert_eq!(sleeps, vec![Duration::from_secs(2), Duration::from_secs(5)]);
    assert_eq!(fs::read_dir(&scratch_root).unwrap().count(), 0);
}

// ---------------------------------------------------------------------------
// Tolerance resolution
// ---------------------------------------------------------------------------

#[test]
fn tolerance_flag_beats_env_and_garbage_warns_loudly() {
    // Pure rules, no env mutation needed.
    let res = resolve_vcs_skip_tolerance_from(Some(9), Some("3"));
    assert_eq!(res.tolerance, 9);
    assert_eq!(res.warning, None);

    let res = resolve_vcs_skip_tolerance_from(None, Some("7"));
    assert_eq!(res.tolerance, 7);
    assert_eq!(res.warning, None);

    for garbage in ["garbage", "0", "-1", "07", ""] {
        let res = resolve_vcs_skip_tolerance_from(None, Some(garbage));
        assert_eq!(
            res.tolerance, DEFAULT_VCS_SKIP_TOLERANCE,
            "garbage '{garbage}' must fall back to 5"
        );
        let warning = res.warning.expect("garbage must warn loudly");
        assert!(
            warning.contains(&format!("GSA_VCS_SKIP_TOLERANCE='{garbage}'")),
            "warning must name the knob: {warning}"
        );
    }

    let res = resolve_vcs_skip_tolerance_from(None, None);
    assert_eq!(res.tolerance, DEFAULT_VCS_SKIP_TOLERANCE);
    assert_eq!(res.warning, None);
}

#[test]
fn tolerance_env_reads_the_process_environment() {
    let fx = Fixture::new("tolerance_env");
    std::env::set_var("GSA_VCS_SKIP_TOLERANCE", "11");
    assert_eq!(resolve_vcs_skip_tolerance(None).tolerance, 11);
    // The flag still beats a valid env value.
    assert_eq!(resolve_vcs_skip_tolerance(Some(4)).tolerance, 4);
    std::env::set_var("GSA_VCS_SKIP_TOLERANCE", "banana");
    let res = resolve_vcs_skip_tolerance(None);
    assert_eq!(res.tolerance, DEFAULT_VCS_SKIP_TOLERANCE);
    assert!(res
        .warning
        .unwrap()
        .contains("GSA_VCS_SKIP_TOLERANCE='banana'"));
    drop(fx); // restores GSA_VCS_SKIP_TOLERANCE
}

// ---------------------------------------------------------------------------
// Remote ref resolution: declared refs only, immutable inputs never query
// ---------------------------------------------------------------------------

#[test]
fn remote_revision_resolves_declared_branch_and_tag_refs() {
    let fx = Fixture::new("remote_refs");

    // Branch: the declared ref, never a bare HEAD.
    fx.stub_git(&format!(
        "case \"$cmd\" in\n  ls-remote) printf '%s\\t%s\\n' '{SHA_A}' 'refs/heads/feature/x' ;;\nesac"
    ));
    let vref = vcs_source_ref_info("git+https://ex.com/foo.git#branch=feature/x").unwrap();
    let revision = vcs_remote_revision(&vref, &mut no_sleeps()).unwrap();
    assert_eq!(revision, SHA_A);
    let log = fx.git_log();
    assert!(log.contains("refs/heads/feature/x"), "log: {log}");
    assert!(
        !log.split_whitespace().any(|word| word == "HEAD"),
        "a branch query must never ask for HEAD: {log}"
    );

    // Tag: peeled `^{}` preferred over the tag object.
    fx.stub_git(&format!(
        "case \"$cmd\" in\n  ls-remote) printf '%s\\t%s\\n' '{SHA_A}' 'refs/tags/v1'; printf '%s\\t%s\\n' '{SHA_B}' 'refs/tags/v1^{{}}' ;;\nesac"
    ));
    let vref = vcs_source_ref_info("git+https://ex.com/foo.git#tag=v1").unwrap();
    let revision = vcs_remote_revision(&vref, &mut no_sleeps()).unwrap();
    assert_eq!(revision, SHA_B, "the peeled commit is what was compiled");
    assert!(fx.git_log().contains("refs/tags/v1^{}"));

    // Default: `ls-remote --symref`, reading the hash row of HEAD.
    fx.stub_git(&format!(
        "case \"$cmd\" in\n  ls-remote) printf 'ref: refs/heads/main\\tHEAD\\n'; printf '%s\\tHEAD\\n' '{SHA_A}' ;;\nesac"
    ));
    let vref = vcs_source_ref_info("git+https://ex.com/foo.git").unwrap();
    let revision = vcs_remote_revision(&vref, &mut no_sleeps()).unwrap();
    assert_eq!(revision, SHA_A);
    let log = fx.git_log();
    assert!(log.contains("--symref"), "log: {log}");
}

#[test]
fn remote_revision_immutable_inputs_never_query_upstream() {
    let fx = Fixture::new("remote_immutable");
    fx.stub_git("echo 'git must not be called' >&2; exit 99\n");

    // Pinned Git commit: lowercased, no query at all.
    let vref = vcs_source_ref_info("git+https://ex.com/foo.git#commit=ABC1234").unwrap();
    assert_eq!(
        vcs_remote_revision(&vref, &mut no_sleeps()).unwrap(),
        "abc1234"
    );
    // Numeric SVN revision: immutable, no query.
    let vref = vcs_source_ref_info("svn+https://ex.com/s#123").unwrap();
    assert_eq!(vcs_remote_revision(&vref, &mut no_sleeps()).unwrap(), "123");
    assert_eq!(fx.git_calls(), 0, "immutable inputs must not fork git");
}

#[test]
fn remote_revision_svn_hg_and_bzr_resolve_through_path_stubs() {
    let fx = Fixture::new("remote_other_vcs");
    fx.stub_tool("svn", "echo 42\n");
    let vref = vcs_source_ref_info("svn+https://ex.com/s").unwrap();
    assert_eq!(vcs_remote_revision(&vref, &mut no_sleeps()).unwrap(), "42");

    fx.stub_tool("hg", &format!("echo {SHA_A}\n"));
    let vref = vcs_source_ref_info("hg+https://ex.com/h#branch=default").unwrap();
    assert_eq!(vcs_remote_revision(&vref, &mut no_sleeps()).unwrap(), SHA_A);

    fx.stub_tool("bzr", "echo rev-123\n");
    let vref = vcs_source_ref_info("bzr+https://ex.com/b").unwrap();
    assert_eq!(
        vcs_remote_revision(&vref, &mut no_sleeps()).unwrap(),
        "rev-123"
    );
}
