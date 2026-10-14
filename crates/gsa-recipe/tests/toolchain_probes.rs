//! Integration probes for `gsa_recipe::toolchain`: the GCC build-identity
//! drift gate, the rustc/cargo sanity probe, and the remediation policy.
//! Everything synthetic — scratch under `CARGO_TARGET_TMPDIR` (the runtime
//! forbids `/tmp` writes here), PATH-stubbed `gcc`/`rustc`/`cargo`/`pacman`
//! with invocation logs, no network, no host toolchain. The engine code under
//! test never reads `GSA_FAKE_*`, so the stubs bake their behaviour into
//! their own bodies instead of env knobs.
//!
//! Red-first discipline: every assertion family has a `falsify_*` test that
//! feeds its checker a MUTATED input and asserts the checker names what broke
//! — a checker that cannot fail is itself caught here.

use std::cell::Cell;
use std::ffi::OsString;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Mutex, MutexGuard};

use gsa_recipe::toolchain::{
    check_identity, clean_targets, force_queue, gcc_identity, marker_path, probe_scratch_base,
    read_marker, remediation_plan, remediation_refusal_text, resolve_probe_scratch,
    rustc_sanity_probe, sanitize_user_tag, write_marker, CleanTargets, IdentityState, ProbeStatus,
    Remediation, GCC_UNAVAILABLE_IDENTITY,
};

static ENV_LOCK: Mutex<()> = Mutex::new(());

/// Serialises every test that mutates the process environment (PATH, TMPDIR,
/// USER) or spawns PATH-resolved stubs, and restores the environment on
/// drop: the Rust harness runs tests as parallel threads of ONE process, and
/// env mutation is process-global.
struct EnvGuard {
    _lock: MutexGuard<'static, ()>,
    saved: Vec<(&'static str, Option<OsString>)>,
}

impl EnvGuard {
    fn lock() -> Self {
        let lock = ENV_LOCK.lock().unwrap_or_else(|err| err.into_inner());
        let saved = ["PATH", "TMPDIR", "USER"]
            .map(|key| (key, std::env::var_os(key)))
            .to_vec();
        EnvGuard { _lock: lock, saved }
    }
}

impl Drop for EnvGuard {
    fn drop(&mut self) {
        for (key, value) in &self.saved {
            match value {
                Some(value) => std::env::set_var(key, value),
                None => std::env::remove_var(key),
            }
        }
    }
}

static SCRATCH_COUNTER: AtomicU32 = AtomicU32::new(0);

/// A unique scratch tree under the harness target dir, removed first so a
/// crashed earlier run cannot fake a result.
fn scratch(name: &str) -> PathBuf {
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!(
        "toolchain-probes-{name}-{}-{}",
        std::process::id(),
        SCRATCH_COUNTER.fetch_add(1, Ordering::SeqCst)
    ));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn write_exec(path: &Path, body: &str) {
    fs::write(path, body).unwrap();
    let mut perms = fs::metadata(path).unwrap().permissions();
    perms.set_mode(0o755);
    fs::set_permissions(path, perms).unwrap();
}

/// Writes PATH stub `name` from `template` with `@@LOG@@` substituted by the
/// invocation-log path. Behaviour knobs (`@@RC@@`, `@@OUT@@`, `@@LINE@@`) are
/// substituted by the caller first — baked bodies keep the engine and the
/// tests free of `GSA_FAKE_*`-style env wiring.
fn stub(bin: &Path, name: &str, template: &str, log: &Path) {
    write_exec(
        &bin.join(name),
        &template.replace("@@LOG@@", &log.display().to_string()),
    );
}

const GCC_TMPL: &str = r#"#!/bin/bash
printf 'gcc LC_ALL=%s %s\n' "${LC_ALL:-unset}" "$*" >>"@@LOG@@"
[[ ${1:-} == --version ]] || exit 2
printf '@@LINE@@\n'
"#;

const RUSTC_TMPL: &str = r#"#!/bin/bash
printf 'rustc %s\n' "$*" >>"@@LOG@@"
out=''
prev=''
for a in "$@"; do
    if [[ $prev == -o ]]; then out=$a; fi
    prev=$a
done
@@OUT@@
exit @@RC@@
"#;

const RUSTC_OUT_CREATE: &str = r#"if [[ -n $out ]]; then : > "$out"; fi"#;

const CARGO_TMPL: &str = r#"#!/bin/bash
printf 'cargo %s\n' "$*" >>"@@LOG@@"
exit @@RC@@
"#;

const PACMAN_TMPL: &str = r#"#!/bin/bash
printf 'pacman %s\n' "$*" >>"@@LOG@@"
exit @@RC@@
"#;

/// The probe's two scratch files, named the way the module names them
/// (`<base>.rs`, `<base>.bin`).
fn probe_files(base: &Path) -> (PathBuf, PathBuf) {
    (
        PathBuf::from(format!("{}.rs", base.display())),
        PathBuf::from(format!("{}.bin", base.display())),
    )
}

// ─── Falsifiable checkers: each names what broke ─────────────────────────────

/// A Drifted rendering must name BOTH build lines verbatim.
fn drift_message_names(
    state: &IdentityState,
    expected_previous: &str,
    expected_current: &str,
) -> Result<(), String> {
    let message = state.to_string();
    if !message.contains(expected_previous) {
        return Err(format!(
            "drift message is missing the previous build line {expected_previous:?}: {message}"
        ));
    }
    if !message.contains(expected_current) {
        return Err(format!(
            "drift message is missing the current build line {expected_current:?}: {message}"
        ));
    }
    Ok(())
}

/// The clean-targets data must cover all three classes the drift clean
/// deletes: trees, archives, VCS sidecars.
fn clean_targets_cover(targets: &CleanTargets, recipe_dir: &Path) -> Result<(), String> {
    for name in ["src", "pkg", "build"] {
        if !targets.trees.contains(&recipe_dir.join(name)) {
            return Err(format!("clean-targets data is missing the {name}/ tree"));
        }
    }
    if targets.archives.is_empty() {
        return Err("clean-targets data lists no *.pkg.tar.zst archive".to_string());
    }
    if targets.sidecars.is_empty() {
        return Err("clean-targets data lists no *.gsa-vcs-revisions sidecar".to_string());
    }
    Ok(())
}

/// A probe failure detail must name the llvm-libs-git/rust-git skew and BOTH
/// recovery options.
fn failure_detail_names_skew(detail: &str) -> Result<(), String> {
    for want in [
        "llvm-libs-git",
        "NEWER than rust-git",
        "downgrade-rebuild llvm-libs",
        "--allow-broken-rustc",
    ] {
        if !detail.contains(want) {
            return Err(format!(
                "probe failure detail is missing {want:?}: {detail}"
            ));
        }
    }
    Ok(())
}

/// A remediation plan must match the expected kind and chain exactly.
fn remediation_matches(
    plan: &Remediation,
    expected_kind: &str,
    expected_chain: &[&str],
) -> Result<(), String> {
    let (kind, chain) = match plan {
        Remediation::Narrow(chain) => ("narrow", chain.as_slice()),
        Remediation::Core(chain) => ("core", chain.as_slice()),
        Remediation::Impossible => ("impossible", [].as_slice()),
    };
    if kind != expected_kind {
        return Err(format!(
            "remediation plan kind mismatch: expected {expected_kind}, got {kind}"
        ));
    }
    let expected: Vec<String> = expected_chain.iter().map(|id| (*id).to_string()).collect();
    if chain != expected.as_slice() {
        return Err(format!(
            "remediation plan chain mismatch: expected {expected:?}, got {chain:?}"
        ));
    }
    Ok(())
}

/// The forced queue must match the expected id order exactly.
fn force_queue_order(actual: &[String], expected: &[&str]) -> Result<(), String> {
    let expected: Vec<String> = expected.iter().map(|id| (*id).to_string()).collect();
    if actual != expected {
        return Err(format!(
            "force_queue order mismatch: expected {expected:?}, got {actual:?}"
        ));
    }
    Ok(())
}

// ─── GCC build-identity drift gate ───────────────────────────────────────────

/// A recipe dir the drift clean would target: the three trees (one holding a
/// stale LTO object), one archive + its VCS sidecar, an in-flight manifest
/// (NOT a clean target), and ordinary recipe files.
fn recipe_fixture(root: &Path) -> PathBuf {
    let recipe = root.join("recipe");
    for dir in ["src", "pkg", "build"] {
        fs::create_dir_all(recipe.join(dir)).unwrap();
    }
    fs::write(recipe.join("src/stale-lto.o"), b"").unwrap();
    fs::write(recipe.join("p1-1.0.0-1-any.pkg.tar.zst"), b"").unwrap();
    fs::write(
        recipe.join("p1-1.0.0-1-any.pkg.tar.zst.gsa-vcs-revisions"),
        b"rev\n",
    )
    .unwrap();
    fs::write(
        recipe.join("p1-1.0.0-1-any.pkg.tar.zst.gsa-vcs-revisions.tmp.4242"),
        b"",
    )
    .unwrap();
    fs::write(recipe.join("PKGBUILD"), b"pkgname=p1\n").unwrap();
    recipe
}

#[test]
fn identity_marker_round_trip() {
    let root = scratch("marker-round-trip");
    let state = root.join("state");
    let line = "gcc (fixture) 17.0.0 20260906";
    assert_eq!(read_marker(&state, "p1").unwrap(), None, "no marker yet");
    write_marker(&state, "p1", line).unwrap();
    assert_eq!(
        marker_path(&state, "p1"),
        state.join("toolchains").join("p1"),
        "the marker must live at <state>/toolchains/<id>"
    );
    assert_eq!(
        read_marker(&state, "p1").unwrap(),
        Some(line.to_string()),
        "written identity must round-trip"
    );
    for bad in ["", "two\nlines", "trailing\n"] {
        assert!(
            write_marker(&state, "p2", bad).is_err(),
            "write_marker must reject the non-single-line identity {bad:?}"
        );
    }
    assert_eq!(
        read_marker(&state, "p2").unwrap(),
        None,
        "a rejected identity must leave no marker behind"
    );
}

#[test]
fn gcc_identity_reads_the_first_build_line_under_lc_all_c() {
    let root = scratch("gcc-first-line");
    let bin = root.join("bin");
    fs::create_dir_all(&bin).unwrap();
    let log = root.join("gcc.log");
    let body = GCC_TMPL
        .replace(
            "@@LINE@@",
            "gcc (fixture) 17.0.0 20260906\\nCopyright (C) fixture",
        )
        .replace("@@LOG@@", &log.display().to_string());
    write_exec(&bin.join("gcc"), &body);
    let _env = EnvGuard::lock();
    std::env::set_var("PATH", &bin);
    assert_eq!(
        gcc_identity().unwrap(),
        "gcc (fixture) 17.0.0 20260906",
        "the identity is the FIRST line of the build banner"
    );
    let log_text = fs::read_to_string(&log).unwrap();
    assert!(
        log_text.contains("LC_ALL=C"),
        "the identity must come from LC_ALL=C gcc --version, log: {log_text}"
    );
}

#[test]
fn gcc_identity_sentinel_when_gcc_is_absent() {
    let root = scratch("gcc-absent");
    let bin = root.join("bin");
    fs::create_dir_all(&bin).unwrap();
    let _env = EnvGuard::lock();
    std::env::set_var("PATH", &bin);
    assert_eq!(
        gcc_identity().unwrap(),
        GCC_UNAVAILABLE_IDENTITY,
        "absent gcc is data, not a refusal (the fish default)"
    );
}

#[test]
fn gcc_identity_errors_when_the_build_line_is_unusable() {
    let root = scratch("gcc-broken");
    let bin = root.join("bin");
    fs::create_dir_all(&bin).unwrap();
    let log = root.join("gcc.log");
    write_exec(
        &bin.join("gcc"),
        &format!(
            "#!/bin/bash\nprintf 'gcc %s\\n' \"$*\" >>\"{}\"\nexit 1\n",
            log.display()
        ),
    );
    let _env = EnvGuard::lock();
    std::env::set_var("PATH", &bin);
    let err = gcc_identity().unwrap_err().to_string();
    assert!(
        err.contains("could not determine the GCC build identity"),
        "a present-but-broken gcc is a hard error, got: {err}"
    );
}

#[test]
fn identity_unchanged_on_the_same_build_line() {
    let root = scratch("identity-unchanged");
    let state = root.join("state");
    let line = "gcc (fixture) 17.0.0 20260906";
    write_marker(&state, "p1", line).unwrap();
    let verdict = check_identity(&state, "p1", line);
    assert_eq!(verdict, IdentityState::Unchanged);
    assert!(
        !verdict.forces_clean_rebuild(),
        "an unchanged identity must not force the drift clean"
    );
}

#[test]
fn identity_drift_reports_both_build_lines() {
    let root = scratch("identity-drift");
    let state = root.join("state");
    let previous = "gcc (fixture) 17.0.0 20260906";
    let current = "gcc (fixture) 17.0.0 20260920";
    write_marker(&state, "p1", previous).unwrap();
    let verdict = check_identity(&state, "p1", current);
    assert_eq!(
        verdict,
        IdentityState::Drifted {
            previous: previous.to_string(),
            current: current.to_string(),
        }
    );
    assert!(
        verdict.forces_clean_rebuild(),
        "drift must force clean+rebuild even under --skip"
    );
    drift_message_names(&verdict, previous, current)
        .unwrap_or_else(|err| panic!("the drift message must name both build lines: {err}"));
}

#[test]
fn falsify_drift_message_checker_names_the_missing_line() {
    let previous = "gcc (fixture) 17.0.0 20260906";
    let current = "gcc (fixture) 17.0.0 20260920";
    // Mutated input: the state carries a DIFFERENT line than the message
    // must name — the checker has to fail and say which side broke.
    let mutated = IdentityState::Drifted {
        previous: "gcc (other) 16.0.0".to_string(),
        current: current.to_string(),
    };
    let err = drift_message_names(&mutated, previous, current).unwrap_err();
    assert!(
        err.contains("previous build line"),
        "checker must name the missing previous line, got: {err}"
    );
    let mutated = IdentityState::Drifted {
        previous: previous.to_string(),
        current: "gcc (other) 16.0.0".to_string(),
    };
    let err = drift_message_names(&mutated, previous, current).unwrap_err();
    assert!(
        err.contains("current build line"),
        "checker must name the missing current line, got: {err}"
    );
}

#[test]
fn identity_missing_lists_every_clean_target() {
    let root = scratch("identity-missing");
    let state = root.join("state");
    let recipe = recipe_fixture(&root);
    let verdict = check_identity(&state, "p1", "gcc (fixture) 17.0.0 20260906");
    assert_eq!(
        verdict,
        IdentityState::Missing,
        "no marker must read as Missing (the one-time clean)"
    );
    assert!(verdict.forces_clean_rebuild());

    let targets = clean_targets(&recipe).unwrap();
    clean_targets_cover(&targets, &recipe).unwrap_or_else(|err| panic!("{err}"));
    assert_eq!(
        targets.archives,
        vec![recipe.join("p1-1.0.0-1-any.pkg.tar.zst")]
    );
    assert_eq!(
        targets.sidecars,
        vec![recipe.join("p1-1.0.0-1-any.pkg.tar.zst.gsa-vcs-revisions")],
        "the in-flight .tmp manifest must not be swept as a sidecar"
    );
    assert!(
        !targets
            .trees
            .iter()
            .any(|path| path.ends_with("stale-lto.o")),
        "trees only — contents are the tree's own recursion"
    );
}

#[test]
fn falsify_clean_targets_checker_names_the_missing_class() {
    let root = scratch("clean-targets-falsify");
    let recipe = recipe_fixture(&root);
    let targets = clean_targets(&recipe).unwrap();
    // Mutated input: drop one whole class at a time and require the checker
    // to name exactly the class that went missing.
    let mutated = CleanTargets {
        sidecars: Vec::new(),
        ..targets.clone()
    };
    let err = clean_targets_cover(&mutated, &recipe).unwrap_err();
    assert!(
        err.contains("sidecar"),
        "checker must name the missing sidecar class, got: {err}"
    );
    let mutated = CleanTargets {
        trees: Vec::new(),
        ..targets
    };
    let err = clean_targets_cover(&mutated, &recipe).unwrap_err();
    assert!(
        err.contains("tree"),
        "checker must name the missing tree class, got: {err}"
    );
}

#[test]
fn identity_marker_survives_a_failed_build_so_the_retry_cleans_again() {
    // Caller contract (docs/build-guide.md): the marker is written ONLY after
    // a successful build + VCS-baseline recording. Simulate the
    // toolchain-drift fixture's failed drift build — the gate observes drift
    // and the caller never calls write_marker — the retry must drift again.
    let root = scratch("identity-failed-build");
    let state = root.join("state");
    let previous = "gcc (fixture) 17.0.0 20260906";
    let current = "gcc (fixture) 17.0.0 20260920";
    write_marker(&state, "p1", previous).unwrap();
    assert!(
        check_identity(&state, "p1", current).forces_clean_rebuild(),
        "first drift observation"
    );
    // ... the build fails: no write_marker call happens ...
    assert_eq!(
        read_marker(&state, "p1").unwrap(),
        Some(previous.to_string()),
        "a failed build must not commit the new identity"
    );
    assert!(
        matches!(
            check_identity(&state, "p1", current),
            IdentityState::Drifted { .. }
        ),
        "the retry must observe drift again and re-clean"
    );
}

// ─── rustc/cargo sanity probe ────────────────────────────────────────────────

fn stub_bin(root: &Path) -> PathBuf {
    let bin = root.join("bin");
    fs::create_dir_all(&bin).unwrap();
    bin
}

fn stub_rc(bin: &Path, name: &str, template: &str, log: &Path, rc: u32) {
    stub(bin, name, &template.replace("@@RC@@", &rc.to_string()), log);
}

fn rustc_body(log: &Path, rc: u32, create_output: bool) -> String {
    RUSTC_TMPL
        .replace(
            "@@OUT@@",
            if create_output {
                RUSTC_OUT_CREATE
            } else {
                "true"
            },
        )
        .replace("@@RC@@", &rc.to_string())
        .replace("@@LOG@@", &log.display().to_string())
}

#[test]
fn probe_skips_and_never_invokes_rustc_without_house_rust_git() {
    let root = scratch("probe-skip-no-rust-git");
    let bin = stub_bin(&root);
    let pacman_log = root.join("pacman.log");
    let rustc_log = root.join("rustc.log");
    let cargo_log = root.join("cargo.log");
    stub_rc(&bin, "pacman", PACMAN_TMPL, &pacman_log, 1);
    write_exec(&bin.join("rustc"), &rustc_body(&rustc_log, 0, true));
    stub_rc(&bin, "cargo", CARGO_TMPL, &cargo_log, 0);
    let _env = EnvGuard::lock();
    std::env::set_var("PATH", &bin);
    let base = probe_scratch_base(&root.join("scratch"), "tester");
    match rustc_sanity_probe(&base) {
        ProbeStatus::Skipped { reason } => assert!(
            reason.contains("rust-git"),
            "the skip reason must name the missing house rust-git, got: {reason}"
        ),
        other => panic!("the probe must skip when pacman -Q rust-git fails, got {other:?}"),
    }
    assert!(
        fs::read_to_string(&pacman_log)
            .unwrap()
            .contains("-Q rust-git"),
        "the gate must query exactly pacman -Q rust-git"
    );
    assert!(!rustc_log.exists(), "rustc must never run before its gate");
    assert!(!cargo_log.exists(), "cargo must never run before its gate");
}

#[test]
fn probe_skips_when_rustc_is_not_on_path() {
    let root = scratch("probe-skip-no-rustc");
    let bin = stub_bin(&root);
    let pacman_log = root.join("pacman.log");
    stub_rc(&bin, "pacman", PACMAN_TMPL, &pacman_log, 0);
    let _env = EnvGuard::lock();
    std::env::set_var("PATH", &bin);
    let scratch_dir = root.join("scratch");
    fs::create_dir_all(&scratch_dir).unwrap();
    let base = probe_scratch_base(&scratch_dir, "tester");
    match rustc_sanity_probe(&base) {
        ProbeStatus::Skipped { reason } => assert!(
            reason.contains("rustc is not on PATH"),
            "the skip reason must name the absent rustc, got: {reason}"
        ),
        other => panic!("the probe must skip when rustc is absent, got {other:?}"),
    }
    let (rs, _) = probe_files(&base);
    assert!(!rs.exists(), "a skipped probe must write no scratch");
}

#[test]
fn probe_ok_scratch_lives_under_the_resolved_base_and_is_removed() {
    let root = scratch("probe-ok");
    let bin = stub_bin(&root);
    let pacman_log = root.join("pacman.log");
    let rustc_log = root.join("rustc.log");
    let cargo_log = root.join("cargo.log");
    stub_rc(&bin, "pacman", PACMAN_TMPL, &pacman_log, 0);
    write_exec(&bin.join("rustc"), &rustc_body(&rustc_log, 0, true));
    stub_rc(&bin, "cargo", CARGO_TMPL, &cargo_log, 0);
    let _env = EnvGuard::lock();
    std::env::set_var("PATH", &bin);
    let scratch_dir = root.join("scratch");
    fs::create_dir_all(&scratch_dir).unwrap();
    let base = probe_scratch_base(&scratch_dir, "tester");
    assert_eq!(rustc_sanity_probe(&base), ProbeStatus::Ok);
    let (rs, binary) = probe_files(&base);
    let rustc_log_text = fs::read_to_string(&rustc_log).unwrap();
    assert!(
        rustc_log_text.contains(&rs.display().to_string()),
        "the trivial compile must read the scratch source under the resolved base, log: {rustc_log_text}"
    );
    assert!(
        rustc_log_text.contains(&binary.display().to_string()),
        "the trivial compile must write the scratch binary under the resolved base, log: {rustc_log_text}"
    );
    assert!(
        fs::read_to_string(&cargo_log)
            .unwrap()
            .contains("--version"),
        "the documented cargo probe is `cargo --version`"
    );
    assert!(
        !rs.exists() && !binary.exists(),
        "probe scratch must be cleaned up"
    );
    let leftovers: Vec<_> = fs::read_dir(&scratch_dir)
        .unwrap()
        .map(|entry| entry.unwrap().file_name())
        .collect();
    assert!(
        leftovers.is_empty(),
        "the probe must leave nothing behind, found {leftovers:?}"
    );
}

#[test]
fn probe_failure_detail_names_the_skew_and_both_recovery_options() {
    let root = scratch("probe-fail-rustc");
    let bin = stub_bin(&root);
    let pacman_log = root.join("pacman.log");
    let rustc_log = root.join("rustc.log");
    let cargo_log = root.join("cargo.log");
    stub_rc(&bin, "pacman", PACMAN_TMPL, &pacman_log, 0);
    write_exec(&bin.join("rustc"), &rustc_body(&rustc_log, 139, false));
    stub_rc(&bin, "cargo", CARGO_TMPL, &cargo_log, 0);
    let _env = EnvGuard::lock();
    std::env::set_var("PATH", &bin);
    let scratch_dir = root.join("scratch");
    fs::create_dir_all(&scratch_dir).unwrap();
    let base = probe_scratch_base(&scratch_dir, "tester");
    let status = rustc_sanity_probe(&base);
    let ProbeStatus::Failed { detail } = &status else {
        panic!("a rustc that dies on a trivial compile must fail the probe, got {status:?}");
    };
    assert!(
        detail.contains("139"),
        "the detail must carry the exit status, got: {detail}"
    );
    failure_detail_names_skew(detail).unwrap_or_else(|err| panic!("{err}"));
    let (rs, binary) = probe_files(&base);
    assert!(
        !rs.exists() && !binary.exists(),
        "a failed probe must still clean its scratch"
    );
    assert!(
        !cargo_log.exists(),
        "cargo is not probed after the rustc failure"
    );
}

#[test]
fn falsify_probe_failure_checker_names_the_missing_recovery_option() {
    let root = scratch("probe-detail-falsify");
    let bin = stub_bin(&root);
    let pacman_log = root.join("pacman.log");
    let rustc_log = root.join("rustc.log");
    let cargo_log = root.join("cargo.log");
    stub_rc(&bin, "pacman", PACMAN_TMPL, &pacman_log, 0);
    write_exec(&bin.join("rustc"), &rustc_body(&rustc_log, 139, false));
    stub_rc(&bin, "cargo", CARGO_TMPL, &cargo_log, 0);
    let _env = EnvGuard::lock();
    std::env::set_var("PATH", &bin);
    let scratch_dir = root.join("scratch");
    fs::create_dir_all(&scratch_dir).unwrap();
    let base = probe_scratch_base(&scratch_dir, "tester");
    let ProbeStatus::Failed { detail } = rustc_sanity_probe(&base) else {
        panic!("expected a failed probe");
    };
    // The real detail must pass its own checker ...
    failure_detail_names_skew(&detail)
        .unwrap_or_else(|err| panic!("the real detail must name the skew: {err}"));
    // ... and the checker must fail on MUTATED input, naming the break.
    let mutated = detail.replace("downgrade-rebuild llvm-libs", "fix it somehow");
    let err = failure_detail_names_skew(&mutated).unwrap_err();
    assert!(
        err.contains("downgrade-rebuild llvm-libs"),
        "checker must name the missing recovery option, got: {err}"
    );
    let truncated = detail.lines().take(1).collect::<String>();
    let err = failure_detail_names_skew(&truncated).unwrap_err();
    assert!(
        err.contains("llvm-libs-git"),
        "checker must name the missing skew line, got: {err}"
    );
}

#[test]
fn probe_fails_when_the_cargo_probe_fails() {
    let root = scratch("probe-fail-cargo");
    let bin = stub_bin(&root);
    let pacman_log = root.join("pacman.log");
    let rustc_log = root.join("rustc.log");
    let cargo_log = root.join("cargo.log");
    stub_rc(&bin, "pacman", PACMAN_TMPL, &pacman_log, 0);
    write_exec(&bin.join("rustc"), &rustc_body(&rustc_log, 0, true));
    stub_rc(&bin, "cargo", CARGO_TMPL, &cargo_log, 3);
    let _env = EnvGuard::lock();
    std::env::set_var("PATH", &bin);
    let scratch_dir = root.join("scratch");
    fs::create_dir_all(&scratch_dir).unwrap();
    let base = probe_scratch_base(&scratch_dir, "tester");
    let status = rustc_sanity_probe(&base);
    let ProbeStatus::Failed { detail } = &status else {
        panic!("a failing cargo probe must fail the probe, got {status:?}");
    };
    assert!(
        detail.contains("cargo"),
        "the detail must name the failing cargo probe, got: {detail}"
    );
    failure_detail_names_skew(detail).unwrap_or_else(|err| panic!("{err}"));
    assert!(
        rustc_log.exists(),
        "the trivial compile runs before the cargo probe"
    );
}

#[test]
fn resolve_probe_scratch_honours_tmpdir_and_sanitizes_the_user_tag() {
    let root = scratch("probe-scratch-resolution");
    assert_eq!(sanitize_user_tag("ok_User9"), "ok_User9");
    assert_eq!(
        sanitize_user_tag("we-ird.user"),
        "we_ird_user",
        "only [A-Za-z0-9_] survives; every other character becomes one _"
    );
    let _env = EnvGuard::lock();
    std::env::set_var("TMPDIR", root.join("tmpx"));
    std::env::set_var("USER", "we-ird.user");
    assert_eq!(
        resolve_probe_scratch(),
        root.join("tmpx").join("build_all_rustc_probe_we_ird_user"),
        "scratch base is $TMPDIR/build_all_rustc_probe_<sanitized user>"
    );
}

// ─── Remediation policy + force_queue ────────────────────────────────────────

#[test]
fn remediation_narrows_to_a_known_consumer() {
    let core: Vec<String> = ["llvm-git", "tc1", "c2"].map(String::from).to_vec();
    let known_calls = Cell::new(0);
    let consumer_calls = Cell::new(0);
    let plan = remediation_plan(
        "llvm-git",
        "rust-git",
        &|pkg| {
            known_calls.set(known_calls.get() + 1);
            pkg == "rust-git"
        },
        &|pkg| {
            consumer_calls.set(consumer_calls.get() + 1);
            pkg == "rust-git"
        },
        &core,
    );
    assert_eq!(plan, Remediation::Narrow(vec!["rust-git".to_string()]));
    assert_eq!(
        known_calls.get(),
        1,
        "the known oracle is consulted exactly once"
    );
    assert_eq!(
        consumer_calls.get(),
        1,
        "the consumer oracle is consulted exactly once"
    );
    remediation_matches(&plan, "narrow", &["rust-git"]).unwrap_or_else(|err| panic!("{err}"));
}

#[test]
fn remediation_mirrors_the_self_including_consumer_closure() {
    // fish `expand_consumers` seeds its closure with the toolchain package
    // itself, so a probe implicating the toolchain package narrows to it. The
    // oracle carries that decision — pin the mirror.
    let core: Vec<String> = ["llvm-git", "tc1"].map(String::from).to_vec();
    let plan = remediation_plan("llvm-git", "llvm-git", &|_| true, &|_| true, &core);
    assert_eq!(plan, Remediation::Narrow(vec!["llvm-git".to_string()]));
}

#[test]
fn remediation_cores_when_the_consumer_is_unknown() {
    let core: Vec<String> = ["llvm-git", "tc1", "c2"].map(String::from).to_vec();
    let consumer_calls = Cell::new(0);
    let plan = remediation_plan(
        "llvm-git",
        "rust-git", // installed on the system but unknown to this topology
        &|_| false,
        &|_| {
            consumer_calls.set(consumer_calls.get() + 1);
            true
        },
        &core,
    );
    assert_eq!(plan, Remediation::Core(core));
    assert_eq!(
        consumer_calls.get(),
        0,
        "an unknown consumer short-circuits before the consumer walk"
    );
    remediation_matches(&plan, "core", &["llvm-git", "tc1", "c2"])
        .unwrap_or_else(|err| panic!("{err}"));
}

#[test]
fn remediation_cores_when_the_known_package_is_not_a_consumer() {
    let core: Vec<String> = ["llvm-git", "tc1", "c2"].map(String::from).to_vec();
    let plan = remediation_plan("llvm-git", "p2", &|pkg| pkg == "p2", &|_| false, &core);
    assert_eq!(plan, Remediation::Core(core));
}

#[test]
fn remediation_is_impossible_with_an_empty_core_roster() {
    let plan = remediation_plan("llvm-git", "p2", &|_| false, &|_| false, &[]);
    assert_eq!(
        plan,
        Remediation::Impossible,
        "no narrow hit and no core roster leaves nothing to remediate"
    );
    // ... but a narrow hit still wins even with an empty roster.
    let plan = remediation_plan("llvm-git", "rust-git", &|_| true, &|_| true, &[]);
    assert_eq!(plan, Remediation::Narrow(vec!["rust-git".to_string()]));
    let refusal = remediation_refusal_text();
    assert!(
        refusal.contains("same pass") && refusal.contains("--skip"),
        "the refusal text must carry the recovery steps, got: {refusal}"
    );
}

#[test]
fn remediation_skips_the_oracles_for_an_empty_consumer() {
    let core: Vec<String> = ["llvm-git", "tc1"].map(String::from).to_vec();
    let known_calls = Cell::new(0);
    let consumer_calls = Cell::new(0);
    let plan = remediation_plan(
        "llvm-git",
        "",
        &|_| {
            known_calls.set(known_calls.get() + 1);
            true
        },
        &|_| {
            consumer_calls.set(consumer_calls.get() + 1);
            true
        },
        &core,
    );
    assert_eq!(plan, Remediation::Core(core));
    assert_eq!(known_calls.get(), 0, "an empty consumer is never looked up");
    assert_eq!(consumer_calls.get(), 0, "an empty consumer is never walked");
}

#[test]
fn falsify_remediation_checker_names_the_mismatch() {
    let plan = Remediation::Core(vec!["llvm-git".to_string(), "tc1".to_string()]);
    let err = remediation_matches(&plan, "narrow", &["rust-git"]).unwrap_err();
    assert!(
        err.contains("kind mismatch"),
        "checker must name the kind break, got: {err}"
    );
    let err = remediation_matches(&plan, "core", &["llvm-git"]).unwrap_err();
    assert!(
        err.contains("chain mismatch"),
        "checker must name the chain break, got: {err}"
    );
}

#[test]
fn force_queue_dedupes_preserving_existing_order() {
    let mut queue = vec!["a".to_string(), "b".to_string()];
    let targets: Vec<String> = ["b", "c", "c", "a", "d"].map(String::from).to_vec();
    assert_eq!(
        force_queue(&mut queue, &targets),
        2,
        "only unseen ids are appended"
    );
    force_queue_order(&queue, &["a", "b", "c", "d"]).unwrap_or_else(|err| panic!("{err}"));
    assert_eq!(
        force_queue(&mut queue, &targets),
        0,
        "a repeat force-queue adds nothing"
    );
}

#[test]
fn falsify_force_queue_checker_names_the_order_break() {
    let queue = vec!["a".to_string(), "b".to_string(), "c".to_string()];
    let err = force_queue_order(&queue, &["a", "c", "b"]).unwrap_err();
    assert!(
        err.contains("order mismatch"),
        "checker must name the order break, got: {err}"
    );
}
