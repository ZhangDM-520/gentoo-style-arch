//! Integration tests for `gsa_recipe::sync` — the `gsa -Sy` version-sync and
//! RULE-18 checksum-anchoring machinery (`docs/gsa-contract.md` §B.4).
//!
//! Every external tool (`pacman`, `curl`, `git`, `bash`, `updpkgsums`,
//! `makepkg`, `vercmp`, `nvchecker`) is a PATH stub in the test scratch
//! directory with scripted responses and an invocation log — the tests never
//! touch the network and never read a real system database. Test scratch
//! lives under `CARGO_TARGET_TMPDIR` (never `/tmp`), and the engine's own
//! `$TMPDIR` scratch gate is exercised through that directory.
//!
//! Rule 18 is pinned twice on purpose: the positive case proves a refreshed
//! sum equals the PROVIDER's published value, and the violation case proves a
//! substituted download (fetched bytes ≠ published hash) can never anchor —
//! it is an integrity stop that restores the PKGBUILD byte-for-byte. That
//! second test is the mutation probe of this module: breaking the restore
//! path must fail it by name.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};

use gsa_recipe::sync::*;

// ---------------------------------------------------------------------------
// Harness: scratch dirs, PATH stubs, env plumbing
// ---------------------------------------------------------------------------

/// PATH/TMPDIR are process-global; serialize the tests that swap them.
static ENV_LOCK: Mutex<()> = Mutex::new(());

struct Scratch {
    _guard: MutexGuard<'static, ()>,
    root: PathBuf,
    workspace: PathBuf,
    bin: PathBuf,
    stub: PathBuf,
    tmp: PathBuf,
    log: PathBuf,
    saved: Vec<(&'static str, Option<std::ffi::OsString>)>,
}

impl Scratch {
    fn new(name: &str) -> Scratch {
        let guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let root = PathBuf::from(env!("CARGO_TARGET_TMPDIR"))
            .join("sync_anchoring")
            .join(name);
        let _ = fs::remove_dir_all(&root);
        for d in ["workspace", "bin", "stub", "tmp"] {
            fs::create_dir_all(root.join(d)).unwrap();
        }
        let log = root.join("stub.log");
        fs::write(&log, "").unwrap();
        let ambient_path = std::env::var_os("PATH").unwrap_or_default();
        let mut saved = Vec::new();
        for key in [
            "PATH",
            "TMPDIR",
            "SRCDEST",
            "STUB_LOG",
            "STUB_DIR",
            "STUB_BASH_FAIL_SOURCE",
            "STUB_PACMAN_FAIL",
            "STUB_UPDPKGSUMS_FAIL",
            "STUB_MAKEPKG_FAIL",
            "STUB_GIT_FAIL",
            "STUB_NVCHECKER_FAIL",
        ] {
            saved.push((key, std::env::var_os(key)));
            std::env::remove_var(key);
        }
        let scratch = Scratch {
            _guard: guard,
            workspace: root.join("workspace"),
            bin: root.join("bin"),
            stub: root.join("stub"),
            tmp: root.join("tmp"),
            log,
            root,
            saved,
        };
        std::env::set_var("STUB_LOG", &scratch.log);
        std::env::set_var("STUB_DIR", &scratch.stub);
        scratch.write_stubs();
        scratch.use_stub_path_with_ambient(ambient_path);
        scratch
    }

    fn use_stub_path_with_ambient(&self, ambient: std::ffi::OsString) {
        let mut path = self.bin.as_os_str().to_os_string();
        path.push(":");
        path.push(ambient);
        std::env::set_var("PATH", path);
        std::env::set_var("TMPDIR", &self.tmp);
    }

    /// PATH = stub bin only: for the "tool missing" gate tests, so a real
    /// `updpkgsums`/`vercmp` further along the ambient PATH cannot shadow the
    /// intended absence.
    fn use_stub_path_only(&self) {
        std::env::set_var("PATH", &self.bin);
        std::env::set_var("TMPDIR", &self.tmp);
    }

    fn write_stubs(&self) {
        // The bash stub logs and delegates: recipe evaluation must source
        // PKGBUILDs with real bash, exactly as the engine contract demands.
        self.stub_script(
            "bash",
            r#"#!/bin/bash
printf 'bash %s\n' "$1" >> "$STUB_LOG"
if [ -n "$STUB_BASH_FAIL_SOURCE" ]; then
    case "$2" in
        *__gsa_arr_name*) exit 2 ;;
    esac
fi
exec /bin/bash "$@"
"#,
        );
        self.stub_script(
            "pacman",
            r#"#!/bin/bash
printf 'pacman %s (LC_ALL=%s)\n' "$*" "${LC_ALL:-}" >> "$STUB_LOG"
if [ -n "$STUB_PACMAN_FAIL" ]; then
    printf 'error: database not synced\n' >&2
    exit 1
fi
name=""
for a in "$@"; do
    case "$a" in
        -Si) ;;
        *) name="$a" ;;
    esac
done
resp="$STUB_DIR/pacman/$name"
if [ -f "$resp" ]; then
    cat "$resp"
    exit 0
fi
printf "error: package '%s' was not found\n" "$name" >&2
exit 1"#,
        );
        self.stub_script(
            "curl",
            r#"#!/bin/bash
printf 'curl %s\n' "$*" >> "$STUB_LOG"
out=""
url=""
writeout=0
prev=""
for a in "$@"; do
    case "$prev" in
        -o|--output) out="$a" ;;
        --write-out) writeout=1 ;;
    esac
    case "$a" in
        http://*|https://*) url="$a" ;;
    esac
    prev="$a"
done
emit() {
    if [ -n "$out" ]; then cp "$1" "$out"; else cat "$1"; fi
}
case "$url" in
    *gitlab.archlinux.org*)
        rest="${url#*packages/}"
        c="${rest%%/*}"
        ref="${rest#*-/raw/}"
        ref="${ref%%/*}"
        resp="$STUB_DIR/curl/gitlab-$c-$ref.SRCINFO"
        if [ -f "$resp" ]; then emit "$resp"; [ "$writeout" = 1 ] && printf 200; exit 0; fi
        [ "$writeout" = 1 ] && printf 404
        exit 22 ;;
    *aur.archlinux.org*)
        h="${url##*h=}"
        resp="$STUB_DIR/curl/aur-$h.SRCINFO"
        if [ -f "$resp" ]; then emit "$resp"; [ "$writeout" = 1 ] && printf 200; exit 0; fi
        [ "$writeout" = 1 ] && printf 404
        exit 22 ;;
    *api.github.com*)
        tag="${url##*/tags/}"
        resp="$STUB_DIR/curl/gh-$tag.json"
        if [ -f "$resp" ]; then emit "$resp"; [ "$writeout" = 1 ] && printf 200; exit 0; fi
        [ "$writeout" = 1 ] && printf 404
        exit 0 ;;
    *)
        [ "$writeout" = 1 ] && printf 404
        exit 22 ;;
esac"#,
        );
        self.stub_script(
            "updpkgsums",
            r#"#!/bin/bash
printf 'updpkgsums %s\n' "$*" >> "$STUB_LOG"
# The real tool takes an optional build file and rewrites it IN PLACE, so
# log which file this run targets with both inode identities as they stand
# mid-transaction: the transaction contract is that the committed PKGBUILD
# is never the file an external writer mutates.
buildfile=${1:-PKGBUILD}
case "$buildfile" in
    */*) ;;
    *) buildfile=./$buildfile ;;
esac
printf 'updpkgsums-mutates %s target-ino=%s committed-ino=%s\n' \
    "$buildfile" \
    "$(stat -c %i "$buildfile" 2>/dev/null || printf none)" \
    "$(stat -c %i ./PKGBUILD 2>/dev/null || printf none)" >> "$STUB_LOG"
source "$buildfile" 2>/dev/null || exit 1
q=$'\x27'
vals=()
for s in "${source[@]}"; do
    f="${s%%::*}"
    case "$f" in
        "$s") f="" ;;
    esac
    if [ -z "$f" ]; then
        e="${s#*::}"
        f="${e##*/}"
        f="${f%%[?#]*}"
    fi
    case "$f" in
        *.sig|*.asc|*.signature|*.sign) vals+=("SKIP"); continue ;;
    esac
    if [ -f "$f" ]; then
        vals+=("$(sha256sum <"$f" | cut -d" " -f1)")
    else
        vals+=("SKIP")
    fi
done
line="sha256sums=($q${vals[0]}$q"
for v in "${vals[@]:1}"; do
    line="$line $q$v$q"
done
line="$line)"
sed -i "s/^sha256sums=.*/$line/" "$buildfile"
if [ -n "$STUB_UPDPKGSUMS_FAIL" ]; then
    # Fail AFTER the in-place rewrite: the crash shape the transaction must
    # survive is a partially rewritten build file, not a clean no-op.
    printf 'updpkgsums: died mid-rewrite\n' >&2
    exit 1
fi"#,
        );
        self.stub_script(
            "makepkg",
            r#"#!/bin/bash
printf 'makepkg %s\n' "$*" >> "$STUB_LOG"
if [ -n "$STUB_MAKEPKG_FAIL" ]; then
    printf 'makepkg: cannot read PKGBUILD\n' >&2
    exit 1
fi
printf 'pkgbase = stubpkg\n\tpkgver = 9.9\n'#"#,
        );
        self.stub_script(
            "vercmp",
            r#"#!/bin/bash
printf 'vercmp %s\n' "$*" >> "$STUB_LOG"
if [ "$1" = "$2" ]; then
    echo 0
elif [[ "$1" > "$2" ]]; then
    echo 1
else
    echo -1
fi"#,
        );
        self.stub_script(
            "git",
            r#"#!/bin/bash
printf 'git %s\n' "$*" >> "$STUB_LOG"
if [ -n "$STUB_GIT_FAIL" ]; then
    exit 1
fi
case " $* " in
    *" archive "*) cat "$STUB_DIR/git/archive.bin"; exit 0 ;;
esac
exit 0"#,
        );
        self.stub_script(
            "nvchecker",
            r#"#!/bin/bash
printf 'nvchecker %s\n' "$*" >> "$STUB_LOG"
cfg=""
prev=""
for a in "$@"; do
    [ "$prev" = "-c" ] && cfg="$a"
    prev="$a"
done
state=$(sed -n 's/^newver = "\(.*\)"/\1/p' "$cfg")
oldstate=$(sed -n 's/^oldver = "\(.*\)"/\1/p' "$cfg")
printf 'nvchecker-state oldver=%s newver=%s\n' "$oldstate" "$state" >> "$STUB_LOG"
if [ -n "$STUB_NVCHECKER_FAIL" ]; then
    printf 'nvchecker: cannot connect\n' >&2
    exit 1
fi
cp "$STUB_DIR/nvchecker/new_ver.json" "$state"
"#,
        );
    }

    fn stub_script(&self, name: &str, body: &str) {
        let p = self.bin.join(name);
        fs::write(&p, body).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&p, fs::Permissions::from_mode(0o755)).unwrap();
        }
    }

    fn recipe(&self, category: &str, name: &str, pkgbuild: &str) -> PathBuf {
        let dir = self.workspace.join("packages").join(category).join(name);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("PKGBUILD"), pkgbuild).unwrap();
        dir
    }

    fn put(&self, rel: &str, bytes: &[u8]) {
        let p = self.root.join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, bytes).unwrap();
    }

    fn pacman_answer(&self, name: &str, version: &str) {
        self.put(
            &format!("stub/pacman/{name}"),
            format!(
                "Repository      : extra\nName            : {name}\nVersion         : {version}\n"
            )
            .as_bytes(),
        );
    }

    fn curl_file(&self, name: &str, content: &str) {
        self.put(&format!("stub/curl/{name}"), content.as_bytes());
    }

    fn log(&self) -> String {
        fs::read_to_string(&self.log).unwrap()
    }

    fn policy(&self) -> SyncPolicy {
        SyncPolicy {
            repo_root: self.workspace.clone(),
        }
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        for (key, value) in &self.saved {
            match value {
                Some(v) => std::env::set_var(key, v),
                None => std::env::remove_var(key),
            }
        }
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn sha256(bytes: &[u8]) -> String {
    hash_bytes("sha256", bytes).unwrap()
}

fn sha512(bytes: &[u8]) -> String {
    hash_bytes("sha512", bytes).unwrap()
}

fn read(path: &Path) -> String {
    fs::read_to_string(path).unwrap()
}

fn pkgbuild_bytes(dir: &Path) -> Vec<u8> {
    fs::read(dir.join("PKGBUILD")).unwrap()
}

/// In-process provider: carries versions AND published checksums, so a test
/// can prove the anchor value comes from the provider and not from whatever
/// the fetch delivered.
struct FakeProvider {
    family: ProviderFamily,
    answer: Result<VersionAnswer, ProviderError>,
    release: Result<ReleaseMetadata, ProviderError>,
    sums: Result<PublishedSums, ProviderError>,
    coverage: Coverage,
    remote_binding: bool,
    calls: RefCell<Vec<String>>,
}

use std::cell::RefCell;

impl FakeProvider {
    fn new(family: ProviderFamily, pkgver: &str) -> FakeProvider {
        FakeProvider {
            family,
            answer: Ok(VersionAnswer::Found(
                VersionFields::parse(&format!("{pkgver}-1")).unwrap(),
            )),
            release: Ok(ReleaseMetadata {
                pkgrel: "1".to_string(),
                epoch: "0".to_string(),
            }),
            sums: Ok(PublishedSums {
                entries: BTreeMap::new(),
                extras: Vec::new(),
                published_id: "fake".to_string(),
            }),
            coverage: Coverage::Covered { extras: Vec::new() },
            remote_binding: false,
            calls: RefCell::new(Vec::new()),
        }
    }

    fn with_sums(mut self, entries: Vec<(&str, &str, &str)>, published_id: &str) -> FakeProvider {
        let mut map = BTreeMap::new();
        for (key, alg, value) in entries {
            map.insert(
                key.to_string(),
                PublishedSum {
                    algorithm: alg.to_string(),
                    value: value.to_string(),
                },
            );
        }
        self.sums = Ok(PublishedSums {
            entries: map,
            extras: Vec::new(),
            published_id: published_id.to_string(),
        });
        self
    }
}

impl VersionProvider for FakeProvider {
    fn label(&self) -> String {
        match self.family {
            ProviderFamily::Arch => "Arch repo".to_string(),
            ProviderFamily::Aur => "AUR aurid".to_string(),
            ProviderFamily::Github => "GitHub o/r".to_string(),
            ProviderFamily::Other => "provider".to_string(),
        }
    }

    fn family(&self) -> ProviderFamily {
        self.family
    }

    fn query_name(&self, name: &str) -> Result<VersionAnswer, ProviderError> {
        self.calls.borrow_mut().push(format!("query:{name}"));
        self.answer.clone()
    }

    fn release_metadata(
        &self,
        _info: &RecipeInfo,
        _pkgver: &str,
    ) -> Result<ReleaseMetadata, ProviderError> {
        self.calls.borrow_mut().push("release_metadata".to_string());
        self.release.clone()
    }

    fn published_sums(
        &self,
        _info: &RecipeInfo,
        _version: &VersionFields,
    ) -> Result<PublishedSums, ProviderError> {
        self.calls.borrow_mut().push("published_sums".to_string());
        self.sums.clone()
    }

    fn anchor_key(&self, entry: &SourceEntry) -> Option<String> {
        if self.remote_binding {
            entry.remote_basename()
        } else {
            entry.filename()
        }
    }

    fn check_coverage(&self, _info: &RecipeInfo) -> Coverage {
        self.coverage.clone()
    }
}

const RULE18_PKG: &str = r#"pkgname=(rule18)
pkgver=1.0
pkgrel=1
source=("a-$pkgver.tar.gz::https://example.org/a-$pkgver.tar.gz" "b-$pkgver.tar.gz::https://example.org/b-$pkgver.tar.gz" "c-$pkgver.tar.gz::https://example.org/c-$pkgver.tar.gz" "a-$pkgver.tar.gz.sign")
sha256sums=('old-a' 'old-b' 'old-c' 'SKIP')
"#;

/// Place the three "fetched" artifacts the rewrite will move to at 1.1.
fn stage_rule18_fetches(scratch: &Scratch, dir: &Path) -> (Vec<u8>, Vec<u8>, Vec<u8>) {
    let a: Vec<u8> = b"AAA-artifact-bytes".to_vec();
    let b: Vec<u8> = b"BBB-artifact-bytes".to_vec();
    let c: Vec<u8> = b"CCC-artifact-bytes".to_vec();
    fs::write(dir.join("a-1.1.tar.gz"), &a).unwrap();
    fs::write(dir.join("b-1.1.tar.gz"), &b).unwrap();
    fs::write(dir.join("c-1.1.tar.gz"), &c).unwrap();
    let _ = scratch;
    (a, b, c)
}

// ---------------------------------------------------------------------------
// RULE 18
// ---------------------------------------------------------------------------

/// Positive: the provider yields a new version AND publishes checksums; the
/// rewritten recipe's sums equal the PROVIDER's published values (a sha256
/// published value must appear verbatim in the recipe; a sha512 published
/// value verifies the same artifact with a different algorithm). The
/// disposition rows render in the run-level shape.
#[test]
fn rule18_positive_anchors_provider_sums_and_renders_disposition() {
    let s = Scratch::new("rule18_positive");
    let dir = s.recipe("stable", "rule18", RULE18_PKG);
    let (a, b, _c) = stage_rule18_fetches(&s, &dir);

    let provider = FakeProvider::new(ProviderFamily::Arch, "1.1").with_sums(
        vec![
            ("a-1.1.tar.gz", "sha512", &sha512(&a)),
            ("b-1.1.tar.gz", "sha256", &sha256(&b)),
        ],
        "rule18",
    );
    let report = sync_arch(&dir, &provider, &s.policy());

    assert!(
        matches!(
            report.outcome,
            SyncOutcome::VersionMoved { ref new, .. } if new == "1.1-1"
        ),
        "expected VersionMoved, got {:?}",
        report.outcome
    );
    match &report.anchor {
        Some(AnchorOutcome::Anchored {
            anchored,
            refresh_only,
            published,
            pkgver,
            ..
        }) => {
            assert_eq!(*anchored, 2);
            assert_eq!(refresh_only, &vec!["c-1.1.tar.gz".to_string()]);
            assert_eq!(published, "rule18");
            assert_eq!(pkgver, "1.1");
        }
        other => panic!("expected Anchored, got {other:?}"),
    }

    // The recipe's own sums now describe the artifacts — and for `b` the
    // value IS the provider's published value verbatim (sha256 both sides).
    let text = read(&dir.join("PKGBUILD"));
    let sums_line = text
        .lines()
        .find(|l| l.starts_with("sha256sums="))
        .unwrap()
        .to_string();
    assert!(
        sums_line.contains(&sha256(&b)),
        "recipe sum must equal the provider's published value: {sums_line}"
    );
    // Algorithms need not match: `a` anchored through the provider's sha512.
    assert!(sums_line.contains(&sha256(&a)));
    // The signature entry moved too but is outside checksum anchoring.
    assert!(sums_line.contains("SKIP"));

    let rendered = render_disposition(&report.rows);
    assert!(rendered.starts_with(
        "Version and checksum sync this run (uncommitted — review with 'git diff', then commit):\n"
    ));
    assert!(rendered.contains("  rule18: 1.0-1 → 1.1-1 (synced with Arch repo)\n"));
    assert!(rendered.contains(
        "  rule18: checksums refreshed at 1.1 — 2 anchored to the official rule18, 1 refresh-only (fetch-only sums: review before committing)\n"
    ));
    // The loud refresh-only record names the file and the attestation.
    let log = report.log.join("\n");
    assert!(log.contains("NOT anchored"));
    assert!(log.contains("c-1.1.tar.gz"));
    assert!(log.contains("'--no-sync' builds the committed version as-is"));
}

/// RULE-18 violation: the provider publishes a hash that the fetched bytes do
/// NOT match — a substituted download must not anchor. The outcome is an
/// integrity stop with file/want/got and the PKGBUILD is restored
/// byte-identical. MUTATION-PROBE TARGET: breaking the restore path must fail
/// this test by name.
#[test]
fn rule18_violation_integrity_stop_restores_pkgbuild() {
    let s = Scratch::new("rule18_violation");
    let dir = s.recipe("stable", "rule18v", RULE18_PKG);
    let before = pkgbuild_bytes(&dir);
    let (a, b, _c) = stage_rule18_fetches(&s, &dir);

    let want = "0".repeat(64); // provider's published sha256 for a substituted `a`
    let provider = FakeProvider::new(ProviderFamily::Arch, "1.1").with_sums(
        vec![
            ("a-1.1.tar.gz", "sha256", &want),
            ("b-1.1.tar.gz", "sha256", &sha256(&b)),
        ],
        "rule18v",
    );
    let report = sync_arch(&dir, &provider, &s.policy());

    let anchor = report.anchor.as_ref().expect("anchoring must run");
    match anchor {
        AnchorOutcome::IntegrityStop {
            file,
            want: w,
            got,
            restored,
        } => {
            assert_eq!(file, "a-1.1.tar.gz");
            assert_eq!(w, &want);
            assert_eq!(got, &sha256(&a));
            assert_eq!(*restored, RestoreStatus::Restored);
        }
        other => panic!("expected IntegrityStop, got {other:?}"),
    }
    assert!(
        matches!(
            report.outcome,
            SyncOutcome::Refused {
                class: RefusalClass::IntegrityStop,
                ..
            }
        ),
        "integrity stop must refuse the run: {:?}",
        report.outcome
    );
    assert!(
        report.rows.is_empty(),
        "a stopped run renders no disposition rows"
    );
    assert_eq!(
        pkgbuild_bytes(&dir),
        before,
        "the recipe must be restored byte-identical after an integrity stop"
    );
    assert_eq!(
        hash_bytes("sha256", &pkgbuild_bytes(&dir)),
        hash_bytes("sha256", &before),
        "restore must republish the original PKGBUILD bytes"
    );
}

/// Provider outage at the anchoring step: defer (`anchoring-refused`), never
/// invent a version, restore the already-rewritten recipe.
#[test]
fn provider_outage_defers_and_restores_without_inventing_version() {
    let s = Scratch::new("provider_outage");
    let dir = s.recipe("stable", "outage", RULE18_PKG);
    let before = pkgbuild_bytes(&dir);
    stage_rule18_fetches(&s, &dir);

    let mut provider = FakeProvider::new(ProviderFamily::Arch, "1.1");
    provider.sums = Err(ProviderError::Outage("mirror timeout".into()));
    let report = sync_arch(&dir, &provider, &s.policy());

    assert_eq!(report.deferral(), Some("anchoring-refused"));
    assert!(
        matches!(report.outcome, SyncOutcome::Deferred { .. }),
        "an outage is a deferral, not a failure: {:?}",
        report.outcome
    );
    assert!(report.rows.is_empty());
    assert_eq!(
        pkgbuild_bytes(&dir),
        before,
        "a deferred recipe keeps its committed bytes (no invented version)"
    );
}

/// A version-query outage is `QueryFailed` — the committed version's
/// freshness is UNVERIFIED and must never fold into "nothing to do".
#[test]
fn query_outage_is_query_failed_not_nochange() {
    let s = Scratch::new("query_outage");
    let dir = s.recipe("stable", "qout", RULE18_PKG);
    let before = pkgbuild_bytes(&dir);

    let mut provider = FakeProvider::new(ProviderFamily::Arch, "1.1");
    provider.answer = Err(ProviderError::Outage("pacman db not synced".into()));
    let report = sync_arch(&dir, &provider, &s.policy());
    assert!(
        matches!(report.outcome, SyncOutcome::QueryFailed { .. }),
        "got {:?}",
        report.outcome
    );
    assert_eq!(pkgbuild_bytes(&dir), before);
}

// ---------------------------------------------------------------------------
// AUR coverage rules (the opted-in nvchecker path)
// ---------------------------------------------------------------------------

const AUR_PKG: &str = r#"pkgname=(aur1)
pkgver=1.0
pkgrel=1
source=("a-$pkgver.tar.gz::https://example.org/a-$pkgver.tar.gz" "local-fix.patch")
sha256sums=('old' 'SKIP')
"#;

/// Recipe-superset source array: the rewrite is restored and the recipe is
/// parked with `anchoring-refused` — a local fix on an anchored recipe lives
/// inside `prepare()`, never in `source=()` (2026-10-09 gcc-snapshot).
#[test]
fn aur_recipe_superset_defers_anchoring_refused_and_restores() {
    let s = Scratch::new("aur_superset");
    let dir = s.recipe("misc", "aur1", AUR_PKG);
    let before = pkgbuild_bytes(&dir);

    let mut provider = FakeProvider::new(ProviderFamily::Aur, "2.0");
    provider.release = Ok(ReleaseMetadata {
        pkgrel: "2".to_string(),
        epoch: "0".to_string(),
    });
    provider.coverage = Coverage::NotCovered {
        missing: vec!["local-fix.patch".to_string()],
    };
    let report = sync_nvchecker(&dir, &provider, &s.policy());

    assert_eq!(report.deferral(), Some("anchoring-refused"));
    assert!(report.anchor.is_none(), "a coverage refusal never anchors");
    assert_eq!(
        pkgbuild_bytes(&dir),
        before,
        "the rewrite must be restored byte-identical"
    );
}

/// Provider-only extras are reported and never anchored (the one-way
/// coverage direction, 2026-10-07 gcc-snapshot).
#[test]
fn aur_provider_extras_reported_never_anchored() {
    let s = Scratch::new("aur_extras");
    let dir = s.recipe("misc", "aur2", AUR_PKG);
    let bytes = b"AA".to_vec();
    fs::write(dir.join("a-2.0.tar.gz"), &bytes).unwrap();

    let mut provider = FakeProvider::new(ProviderFamily::Aur, "2.0")
        .with_sums(vec![("a-2.0.tar.gz", "sha256", &sha256(&bytes))], "aurid");
    provider.release = Ok(ReleaseMetadata {
        pkgrel: "2".to_string(),
        epoch: "0".to_string(),
    });
    provider.coverage = Coverage::Covered {
        extras: vec!["gcc-ada-repro.patch".to_string()],
    };
    let report = sync_nvchecker(&dir, &provider, &s.policy());

    match &report.anchor {
        Some(AnchorOutcome::Anchored {
            anchored,
            refresh_only,
            ..
        }) => {
            assert_eq!(*anchored, 1);
            assert!(refresh_only.is_empty());
        }
        other => panic!("expected Anchored, got {other:?}"),
    }
    let log = report.log.join("\n");
    assert!(
        log.contains("does not build: gcc-ada-repro.patch"),
        "extras must be reported: {log}"
    );
    assert!(
        !log.contains("gcc-ada-repro.patch: "),
        "extras are never anchored"
    );
    let rendered = render_disposition(&report.rows);
    assert!(rendered.contains("(synced with AUR aurid)"));
    assert!(rendered.contains("checksums re-anchored to AUR aurid 2.0"));
}

/// pkgbase/pkgver mismatch between the AUR document and the recipe/resolved
/// version refuses to anchor (deferred as `anchoring-refused` — the fish
/// reference parks the metadata race), with the recipe untouched.
#[test]
fn aur_pkgbase_pkgver_mismatch_refuses_to_anchor() {
    let s = Scratch::new("aur_mismatch");
    let dir = s.recipe("misc", "aur3", AUR_PKG);
    let before = pkgbuild_bytes(&dir);

    let mut provider = FakeProvider::new(ProviderFamily::Aur, "2.0");
    provider.release = Err(ProviderError::Invalid(
        "AUR .SRCINFO changed or disagrees with nvchecker (expected aurid 2.0, got other 3.0)"
            .into(),
    ));
    let report = sync_nvchecker(&dir, &provider, &s.policy());

    assert_eq!(report.deferral(), Some("anchoring-refused"));
    assert!(
        report.anchor.is_none(),
        "a mismatched document never anchors"
    );
    assert!(report.rows.is_empty());
    assert_eq!(pkgbuild_bytes(&dir), before);
}

// ---------------------------------------------------------------------------
// GitHub digest binding
// ---------------------------------------------------------------------------

const GH_PKG: &str = r#"pkgname=(gh)
pkgver=1.0
pkgrel=3
source=("renamed.tar.gz::https://github.com/o/r/releases/download/$pkgver/asset-name.tar.gz" "nodash.tar.gz::https://github.com/o/r/releases/download/$pkgver/nodash.tar.gz" "trap.tar.gz::https://example.org/$pkgver/trap.tar.gz")
sha256sums=('old-1' 'old-2' 'old-3')
"#;

fn github_fixture(s: &Scratch, name: &str, release_json: &str) -> PathBuf {
    let dir = s.recipe("misc", name, GH_PKG);
    let cfg = dir.join(".nvchecker.toml");
    fs::write(&cfg, "[gh]\nsource = \"github\"\ngithub = \"o/r\"\n").unwrap();
    s.put(
        "stub/nvchecker/new_ver.json",
        br#"{"version":2,"data":{"gh":{"version":"1.1"}}}"#,
    );
    s.curl_file("gh-1.1.json", release_json);
    fs::write(dir.join("renamed.tar.gz"), b"RENAMED-bytes").unwrap();
    fs::write(dir.join("nodash.tar.gz"), b"NODASH-bytes").unwrap();
    fs::write(dir.join("trap.tar.gz"), b"TRAP-bytes").unwrap();
    dir
}

/// The GitHub digest is bound to the configured repository, the release tag
/// and the REMOTE URL basename: `name::url` resolves the asset by the remote
/// basename while `name` stays the local fetched file; a digest for an asset
/// whose source URL is outside the release download pattern can never bind.
#[test]
fn github_digest_binds_repo_tag_and_remote_basename() {
    let s = Scratch::new("github_binding");
    let release = format!(
        r#"{{"tag_name":"1.1","assets":[
        {{"name":"asset-name.tar.gz","digest":"sha256:{renamed}"}},
        {{"name":"nodash.tar.gz"}},
        {{"name":"trap.tar.gz","digest":"sha256:{trap}"}}]}}"#,
        renamed = sha256(b"RENAMED-bytes"),
        trap = sha256(b"TRAP-bytes"),
    );
    let dir = github_fixture(&s, "gh", &release);

    let runner = NvcheckerRunner {
        config: dir.join(".nvchecker.toml"),
        repo_root: s.workspace.clone(),
    };
    let provider = GithubProvider::new(runner, "o/r".to_string());
    let report = sync_nvchecker(&dir, &provider, &s.policy());

    assert!(
        matches!(report.outcome, SyncOutcome::VersionMoved { .. }),
        "got {:?}",
        report.outcome
    );
    match &report.anchor {
        Some(AnchorOutcome::Anchored {
            anchored,
            refresh_only,
            published,
            ..
        }) => {
            assert_eq!(*anchored, 1);
            assert_eq!(
                refresh_only,
                &vec!["nodash.tar.gz".to_string(), "trap.tar.gz".to_string()]
            );
            assert_eq!(published, "o/r");
        }
        other => panic!("expected Anchored, got {other:?}"),
    }
    // `renamed.tar.gz` (the name:: override) is the LOCAL file; its sum came
    // from the digest keyed by the REMOTE basename `asset-name.tar.gz`.
    let text = read(&dir.join("PKGBUILD"));
    let sums_line = text.lines().find(|l| l.starts_with("sha256sums=")).unwrap();
    assert!(sums_line.contains(&sha256(b"RENAMED-bytes")));
    // `trap.tar.gz` shares a basename with a published asset but its URL is
    // not the release download URL — it is fetch-only, never anchored.
    assert!(sums_line.contains(&sha256(b"TRAP-bytes")));
    let rendered = render_disposition(&report.rows);
    assert!(rendered.contains("  gh: 1.0-3 → 1.1-1 (synced with GitHub o/r)\n"));
    assert!(rendered.contains(
        "  gh: checksums refreshed at 1.1 — 1 anchored to GitHub o/r, 2 refresh-only (fetch-only sums: review before committing)\n"
    ));

    // The nvchecker state files stayed outside the repository, and the
    // runner resolved through the PATH stub.
    let log = s.log();
    assert!(
        log.contains("nvchecker -c "),
        "nvchecker must run via PATH: {log}"
    );
    let state_line = log
        .lines()
        .find(|l| l.starts_with("nvchecker-state"))
        .expect("state paths logged");
    assert!(
        state_line.contains(s.tmp.to_str().unwrap()),
        "state must live under TMPDIR: {state_line}"
    );
    assert!(
        !state_line.contains(s.workspace.to_str().unwrap()),
        "state must never live inside the repository: {state_line}"
    );
}

/// A release that publishes NO digest for a moved asset is refresh-only and
/// loudly recorded — never described as upstream verification.
#[test]
fn github_no_published_digest_is_loud_refresh_only() {
    let s = Scratch::new("github_refresh_only");
    let release = r#"{"tag_name":"1.1","assets":[{"name":"asset-name.tar.gz"},{"name":"nodash.tar.gz"},{"name":"trap.tar.gz"}]}"#;
    let dir = github_fixture(&s, "gh2", release);

    let runner = NvcheckerRunner {
        config: dir.join(".nvchecker.toml"),
        repo_root: s.workspace.clone(),
    };
    let provider = GithubProvider::new(runner, "o/r".to_string());
    let report = sync_nvchecker(&dir, &provider, &s.policy());

    match &report.anchor {
        Some(AnchorOutcome::RefreshOnly { files, .. }) => {
            assert_eq!(
                files,
                &vec![
                    "renamed.tar.gz".to_string(),
                    "nodash.tar.gz".to_string(),
                    "trap.tar.gz".to_string()
                ]
            );
        }
        other => panic!("expected RefreshOnly, got {other:?}"),
    }
    let log = report.log.join("\n");
    assert!(log.contains("NOT anchored"));
    assert!(log.contains("'--no-sync' builds the committed version as-is"));
    assert!(
        !log.contains("verified against the fetched sources"),
        "fetch-only sums must never be described as verification: {log}"
    );
    let rendered = render_disposition(&report.rows);
    assert!(rendered.contains("0 anchored to GitHub o/r, 3 refresh-only"));
}

// ---------------------------------------------------------------------------
// Arch policy
// ---------------------------------------------------------------------------

const POLICY_PKG: &str = r#"pkgname=({name})
pkgver={ver}
pkgrel={rel}
{epoch}source=("pol.tar.gz::https://example.org/pol.tar.gz")
sha256sums=('x')
"#;

fn policy_recipe(s: &Scratch, name: &str, ver: &str, rel: &str, epoch: &str) -> PathBuf {
    let epoch_line = if epoch.is_empty() {
        String::new()
    } else {
        format!("epoch={epoch}\n")
    };
    s.recipe(
        "stable",
        name,
        &POLICY_PKG
            .replace("{name}", name)
            .replace("{ver}", ver)
            .replace("{rel}", rel)
            .replace("{epoch}", &epoch_line),
    )
}

/// Never downgrade; keep a local pkgrel ahead at equal pkgver; adopt a repo
/// pkgrel actually ahead; parse epochs (a repo epoch never games the content
/// version into a downgrade).
#[test]
fn arch_policy_never_downgrades_keeps_local_pkgrel_ahead_adopts_repo_pkgrel() {
    let s = Scratch::new("arch_policy");

    // Higher local content pkgver is kept even when the repo carries an epoch.
    let dir = policy_recipe(&s, "pol_a", "7.2", "1", "");
    let mut provider = FakeProvider::new(ProviderFamily::Arch, "1.0");
    provider.answer = Ok(VersionAnswer::Found(
        VersionFields::parse("1:7.1-1").unwrap(),
    ));
    let report = sync_arch(&dir, &provider, &s.policy());
    assert_eq!(
        report.outcome,
        SyncOutcome::NoChange {
            reason: NoChangeReason::NeverDowngrade
        }
    );

    // At equal pkgver a local pkgrel ahead is a deliberate bump (2026-09-28).
    let dir = policy_recipe(&s, "pol_b", "1.0", "2", "");
    let mut provider = FakeProvider::new(ProviderFamily::Arch, "1.0");
    provider.answer = Ok(VersionAnswer::Found(VersionFields::parse("1.0-1").unwrap()));
    let report = sync_arch(&dir, &provider, &s.policy());
    assert_eq!(
        report.outcome,
        SyncOutcome::NoChange {
            reason: NoChangeReason::LocalPkgrelAhead
        }
    );

    // A repo pkgrel actually ahead IS adopted (release-only move).
    let dir = policy_recipe(&s, "pol_c", "1.0", "1", "");
    let mut provider = FakeProvider::new(ProviderFamily::Arch, "1.0");
    provider.answer = Ok(VersionAnswer::Found(VersionFields::parse("1.0-2").unwrap()));
    let report = sync_arch(&dir, &provider, &s.policy());
    assert_eq!(
        report.outcome,
        SyncOutcome::ReleaseMoved {
            old: "1.0-1".to_string(),
            new: "1.0-2".to_string()
        }
    );
    assert!(read(&dir.join("PKGBUILD")).contains("pkgrel=2"));

    // Epoch parsing: a versioned rewrite carries the epoch into the recipe.
    let dir = policy_recipe(&s, "pol_d", "1.4", "1", "");
    let mut provider = FakeProvider::new(ProviderFamily::Arch, "1.5");
    provider.answer = Ok(VersionAnswer::Found(
        VersionFields::parse("2:1.5-1").unwrap(),
    ));
    let report = sync_arch(&dir, &provider, &s.policy());
    assert!(
        matches!(report.outcome, SyncOutcome::VersionMoved { .. }),
        "got {:?}",
        report.outcome
    );
    let text = read(&dir.join("PKGBUILD"));
    assert!(text.contains("pkgver=1.5"));
    assert!(text.contains("pkgrel=1"));
    assert!(text.contains("epoch=2"));
    assert_eq!(VersionFields::parse("2:1.5-1").unwrap().render(), "2:1.5-1");
    assert_eq!(VersionFields::parse("7.2.4-1.1").unwrap().pkgrel, "1.1");
    assert_eq!(VersionFields::parse("2.42.2-1").unwrap().epoch, "0");
}

/// A `pkgver()`-driven recipe is skipped entirely: inserting a literal would
/// pin a dev-branch build to the repo release.
#[test]
fn arch_pkgver_function_recipe_skipped() {
    let s = Scratch::new("pkgver_function");
    let dir = s.recipe(
        "stable",
        "fnpkg",
        "pkgname=(fnpkg)\npkgver() { printf 'r1'; }\npkgrel=1\nsource=(x.patch)\nsha256sums=('SKIP')\n",
    );
    let before = pkgbuild_bytes(&dir);
    let provider = FakeProvider::new(ProviderFamily::Arch, "9.9");
    let report = sync_arch(&dir, &provider, &s.policy());
    assert_eq!(
        report.outcome,
        SyncOutcome::NoChange {
            reason: NoChangeReason::PkgverFunction
        }
    );
    assert_eq!(pkgbuild_bytes(&dir), before);
}

/// The physical `packages/stable` placement gate lives in the pass (the fish
/// reference gates on `$SCRIPT_DIR/packages/stable/*`): a non-stable recipe
/// is untouched and the provider is never queried.
#[test]
fn arch_path_gate_leaves_non_stable_untouched() {
    let s = Scratch::new("path_gate");
    let dir = s.recipe("git", "gitpkg", RULE18_PKG);
    let before = pkgbuild_bytes(&dir);
    let provider = FakeProvider::new(ProviderFamily::Arch, "1.1");
    let report = sync_arch(&dir, &provider, &s.policy());
    assert_eq!(
        report.outcome,
        SyncOutcome::NoChange {
            reason: NoChangeReason::NotStableStaged
        }
    );
    assert!(
        provider.calls.borrow().is_empty(),
        "no provider call may happen"
    );
    assert_eq!(pkgbuild_bytes(&dir), before);
}

/// `&` in a repository version corrupts a rewrite rather than failing it —
/// the charset gate refuses BEFORE the first write.
#[test]
fn charset_refusal_happens_before_first_write() {
    let s = Scratch::new("charset");
    let dir = s.recipe("stable", "unsafe", RULE18_PKG);
    let before = pkgbuild_bytes(&dir);
    let mut provider = FakeProvider::new(ProviderFamily::Arch, "1.1");
    provider.answer = Ok(VersionAnswer::Found(
        VersionFields::parse("1.1&x-1").unwrap(),
    ));
    let report = sync_arch(&dir, &provider, &s.policy());
    assert!(
        matches!(
            report.outcome,
            SyncOutcome::Refused {
                class: RefusalClass::UnsafeVersionText,
                ..
            }
        ),
        "got {:?}",
        report.outcome
    );
    assert_eq!(pkgbuild_bytes(&dir), before);
}

/// "The name is unknown" is nothing to sync to; "the QUERY failed" leaves the
/// committed version's freshness unverified — never the same claim.
#[test]
fn unknown_name_is_nochange_query_failure_is_unverified() {
    let s = Scratch::new("unknown_vs_query_failure");

    let dir = s.recipe("stable", "unknown", RULE18_PKG);
    let mut provider = FakeProvider::new(ProviderFamily::Arch, "1.1");
    provider.answer = Ok(VersionAnswer::UnknownName);
    let report = sync_arch(&dir, &provider, &s.policy());
    assert_eq!(
        report.outcome,
        SyncOutcome::NoChange {
            reason: NoChangeReason::UnknownInRepos
        }
    );

    let dir = s.recipe("stable", "qfail", RULE18_PKG);
    let before = pkgbuild_bytes(&dir);
    let mut provider = FakeProvider::new(ProviderFamily::Arch, "1.1");
    provider.answer = Ok(VersionAnswer::QueryFailed("db not synced".into()));
    let report = sync_arch(&dir, &provider, &s.policy());
    match &report.outcome {
        SyncOutcome::QueryFailed { message } => {
            assert!(message.contains("freshness is unverified"), "{message}");
        }
        other => panic!("expected QueryFailed, got {other:?}"),
    }
    assert_eq!(pkgbuild_bytes(&dir), before);
}

// ---------------------------------------------------------------------------
// Computed pkgver
// ---------------------------------------------------------------------------

const COMPUTED_PKG: &str = r#"pkgname=(comp)
_major=1
_minor=3
pkgver=${_major}.${_minor}
pkgrel=1
source=("c-$pkgver.tar.gz::https://example.org/c-$pkgver.tar.gz")
sha256sums=('old')
"#;

/// A computed `pkgver=${var}…` expression is NEVER clobbered with a literal —
/// its variables are bumped so it evaluates to the new version.
#[test]
fn computed_pkgver_bumps_variables_never_expression() {
    let s = Scratch::new("computed_pkgver");
    let dir = s.recipe("stable", "comp", COMPUTED_PKG);
    fs::write(dir.join("c-1.5.tar.gz"), b"CC").unwrap();

    let provider = FakeProvider::new(ProviderFamily::Arch, "1.5")
        .with_sums(vec![("c-1.5.tar.gz", "sha256", &sha256(b"CC"))], "comp");
    let report = sync_arch(&dir, &provider, &s.policy());

    assert!(
        matches!(
            report.outcome,
            SyncOutcome::VersionMoved { ref old, ref new, .. } if old == "1.3-1" && new == "1.5-1"
        ),
        "got {:?}",
        report.outcome
    );
    let text = read(&dir.join("PKGBUILD"));
    assert!(
        text.contains("pkgver=${_major}.${_minor}"),
        "the expression must survive verbatim:\n{text}"
    );
    assert!(
        text.contains("_minor=5"),
        "the moved variable must be bumped:\n{text}"
    );
    assert!(
        !text.contains("pkgver=1.5"),
        "the expression must never be clobbered"
    );
}

/// An expression this sync cannot rewrite refuses with the typed class and an
/// unchanged recipe.
#[test]
fn unsupported_pkgver_expression_refuses_unchanged() {
    let s = Scratch::new("unsupported_expression");
    let dir = s.recipe(
        "stable",
        "badexpr",
        "pkgname=(badexpr)\npkgver=$(printf 1.0)\npkgrel=1\nsource=(x.patch)\nsha256sums=('SKIP')\n",
    );
    let before = pkgbuild_bytes(&dir);

    let provider = FakeProvider::new(ProviderFamily::Arch, "2.0");
    let report = sync_arch(&dir, &provider, &s.policy());
    match &report.outcome {
        SyncOutcome::Unsupported {
            class: PkgverPlanError::UnsupportedExpression,
            ..
        } => {}
        other => panic!("expected UnsupportedExpression, got {other:?}"),
    }
    assert_eq!(pkgbuild_bytes(&dir), before);
}

// ---------------------------------------------------------------------------
// Transactionality
// ---------------------------------------------------------------------------

/// A staged publish that cannot happen keeps the recipe bytes: the staged
/// name is per-process (`PKGBUILD.tmp.<pid>`) and a directory squatting on it
/// makes staging fail loudly instead of half-writing the recipe.
#[test]
fn staged_publish_failure_keeps_recipe_bytes() {
    let s = Scratch::new("staged_publish");
    let dir = s.recipe("stable", "stagefail", RULE18_PKG);
    let before = pkgbuild_bytes(&dir);
    stage_rule18_fetches(&s, &dir);
    fs::create_dir(dir.join(staged_name())).unwrap();

    let provider = FakeProvider::new(ProviderFamily::Arch, "1.1").with_sums(
        vec![("a-1.1.tar.gz", "sha256", &sha256(b"AAA-artifact-bytes"))],
        "stagefail",
    );
    let report = sync_arch(&dir, &provider, &s.policy());
    assert!(
        matches!(
            report.outcome,
            SyncOutcome::Refused {
                class: RefusalClass::WriteFailed,
                ..
            }
        ),
        "got {:?}",
        report.outcome
    );
    assert_eq!(pkgbuild_bytes(&dir), before);
    assert!(dir.join(staged_name()).is_dir());
}

/// The stub's mutation log must show the committed PKGBUILD was never the
/// file the in-place writer touched — inode identities sampled by the stub
/// at mutation time, so the claim is mid-transaction, not reconstructed
/// after a rename could have hidden it.
fn assert_never_mutated_committed(s: &Scratch) {
    let log = s.log();
    let rows: Vec<&str> = log
        .lines()
        .filter(|l| l.starts_with("updpkgsums-mutates "))
        .collect();
    assert!(!rows.is_empty(), "the stub must log what it mutated: {log}");
    for row in rows {
        let target = log_field(row, "target-ino=");
        let committed = log_field(row, "committed-ino=");
        assert_ne!(
            target, committed,
            "updpkgsums must never rewrite the committed PKGBUILD in place: {row}"
        );
    }
}

fn log_field<'a>(row: &'a str, key: &str) -> &'a str {
    let i = row
        .find(key)
        .unwrap_or_else(|| panic!("missing {key} in {row}"));
    row[i + key.len()..]
        .split_whitespace()
        .next()
        .expect("field value")
}

/// `updpkgsums` rewrites its build file IN PLACE — the run must hand it the
/// staged copy and bring the result back through the transaction's publish,
/// so the committed PKGBUILD is never the mutated file.
#[test]
fn updpkgsums_rewrites_a_staged_copy_never_the_committed_pkgbuild() {
    let s = Scratch::new("updpkgsums_staged");
    let dir = s.recipe("stable", "staged", RULE18_PKG);
    let (a, b, _c) = stage_rule18_fetches(&s, &dir);

    let provider = FakeProvider::new(ProviderFamily::Arch, "1.1").with_sums(
        vec![
            ("a-1.1.tar.gz", "sha256", &sha256(&a)),
            ("b-1.1.tar.gz", "sha256", &sha256(&b)),
        ],
        "staged",
    );
    let report = sync_arch(&dir, &provider, &s.policy());
    assert!(
        matches!(report.outcome, SyncOutcome::VersionMoved { .. }),
        "got {:?}",
        report.outcome
    );
    assert_never_mutated_committed(&s);
    // The refreshed sums still land in the committed recipe — via publish.
    let sums_line = read(&dir.join("PKGBUILD"))
        .lines()
        .find(|l| l.starts_with("sha256sums="))
        .unwrap()
        .to_string();
    assert!(
        sums_line.contains(&sha256(&b)),
        "the staged sums must reach the recipe: {sums_line}"
    );
}

/// `updpkgsums` failing after the rewrite is a deferral — and the rewrite is
/// restored byte-identical (a genuine mid-rewrite failure, not a no-op path).
#[test]
fn updpkgsums_failure_defers_and_restores_byte_identical() {
    let s = Scratch::new("updpkgsums_failure");
    let dir = s.recipe("stable", "upd", RULE18_PKG);
    let before = pkgbuild_bytes(&dir);
    stage_rule18_fetches(&s, &dir);
    std::env::set_var("STUB_UPDPKGSUMS_FAIL", "1");

    let provider = FakeProvider::new(ProviderFamily::Arch, "1.1").with_sums(
        vec![("a-1.1.tar.gz", "sha256", &sha256(b"AAA-artifact-bytes"))],
        "upd",
    );
    let report = sync_arch(&dir, &provider, &s.policy());

    assert_eq!(report.deferral(), Some("anchoring-refused"));
    assert_never_mutated_committed(&s);
    assert_eq!(
        pkgbuild_bytes(&dir),
        before,
        "the recipe must be restored byte-identical after updpkgsums failure"
    );
}

/// A crashed run leaves its sibling staging litter behind; the next
/// transaction sweeps exactly the names this module's own writers create —
/// and nothing else (the tracked files, near-miss names, and a directory
/// that merely shares a pattern all survive).
#[test]
fn transaction_begin_sweeps_own_staging_litter_only() {
    let s = Scratch::new("staging_litter");
    let dir = policy_recipe(&s, "sweep", "1.0", "1", "");
    fs::write(dir.join(".SRCINFO"), "pkgbase = sweep\n\tpkgver = 1.0\n").unwrap();
    let litter = [
        "PKGBUILD.tmp.99999",
        "PKGBUILD.tmp.99999.tmp.99999",
        "PKGBUILD.tmp.99999.restore",
        ".SRCINFO.tmp.99999",
    ];
    for name in litter {
        fs::write(dir.join(name), b"crash litter").unwrap();
    }
    let survivors = ["PKGBUILD", ".SRCINFO", "PKGBUILD.tmp", ".SRCINFO.tmp", "PKGBUILD.orig"];
    for name in ["PKGBUILD.tmp", ".SRCINFO.tmp", "PKGBUILD.orig"] {
        fs::write(dir.join(name), b"not ours").unwrap();
    }
    fs::create_dir(dir.join("PKGBUILD.tmp.keepme")).unwrap();

    let mut provider = FakeProvider::new(ProviderFamily::Arch, "1.0");
    provider.answer = Ok(VersionAnswer::Found(VersionFields::parse("1.0-2").unwrap()));
    let report = sync_arch(&dir, &provider, &s.policy());
    assert!(
        matches!(report.outcome, SyncOutcome::ReleaseMoved { .. }),
        "got {:?}",
        report.outcome
    );

    for name in litter {
        assert!(
            !dir.join(name).exists(),
            "crash litter must not survive the next transaction: {name}"
        );
    }
    for name in survivors {
        assert!(
            dir.join(name).is_file(),
            "the sweep must never touch a non-litter name: {name}"
        );
    }
    assert!(
        dir.join("PKGBUILD.tmp.keepme").is_dir(),
        "a directory squatting on the pattern is never this module's litter"
    );
    // The run itself leaves none of its own behind either: every remaining
    // pattern match is the surviving directory above.
    for entry in fs::read_dir(&dir).unwrap().flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        let ours = name.starts_with("PKGBUILD.tmp.") || name.starts_with(".SRCINFO.tmp.");
        assert!(
            !ours || entry.path().is_dir(),
            "staging litter survived the run: {name}"
        );
    }
}

/// A failed `.SRCINFO` refresh folds into the disposition line loudly — the
/// run summary must not claim a clean sync.
#[test]
fn srcinfo_refresh_failure_folds_into_disposition_line() {
    let s = Scratch::new("srcinfo_refresh");
    let dir = policy_recipe(&s, "staleinfo", "1.0", "1", "");
    fs::write(
        dir.join(".SRCINFO"),
        "pkgbase = staleinfo\n\tpkgver = 1.0\n",
    )
    .unwrap();
    std::env::set_var("STUB_MAKEPKG_FAIL", "1");

    let mut provider = FakeProvider::new(ProviderFamily::Arch, "1.0");
    provider.answer = Ok(VersionAnswer::Found(VersionFields::parse("1.0-2").unwrap()));
    let report = sync_arch(&dir, &provider, &s.policy());

    assert!(matches!(report.outcome, SyncOutcome::ReleaseMoved { .. }));
    let rendered = render_disposition(&report.rows);
    assert!(
        rendered.contains(
            "  staleinfo: 1.0-1 → 1.0-2 (synced with Arch repo) — the committed .SRCINFO could NOT be refreshed; regenerate it with 'makepkg --printsrcinfo' before committing\n"
        ),
        "got:\n{rendered}"
    );
}

/// `updpkgsums` missing is one of the impossible-to-anchor paths: defer
/// `anchoring-refused` and restore the rewrite instead of failing — and
/// never fall back to a fetch-generated hash.
#[test]
fn missing_updpkgsums_tool_defers_anchoring_refused() {
    let s = Scratch::new("missing_updpkgsums");
    let dir = s.recipe("stable", "notool", RULE18_PKG);
    let before = pkgbuild_bytes(&dir);
    stage_rule18_fetches(&s, &dir);
    // PATH = the stub bin only (so no real updpkgsums can shadow the
    // absence) minus the stub itself.
    fs::remove_file(s.bin.join("updpkgsums")).unwrap();
    s.use_stub_path_only();

    let provider = FakeProvider::new(ProviderFamily::Arch, "1.1").with_sums(
        vec![("a-1.1.tar.gz", "sha256", &sha256(b"AAA-artifact-bytes"))],
        "notool",
    );
    let report = sync_arch(&dir, &provider, &s.policy());

    assert_eq!(report.deferral(), Some("anchoring-refused"));
    assert_eq!(pkgbuild_bytes(&dir), before);
}

// ---------------------------------------------------------------------------
// VCS `#tag=` anchoring
// ---------------------------------------------------------------------------

/// A VCS `#tag=` source is anchorable: makepkg's checksum hashes
/// `git archive --format tar <tag>` of the checkout, and the provider's
/// published value is checked against that archive — never against a
/// directory listing.
#[test]
fn vcs_tag_source_verified_via_git_archive() {
    let s = Scratch::new("vcs_tag");
    let dir = s.recipe(
        "stable",
        "vcspkg",
        r#"pkgname=(vcspkg)
pkgver=1.0
pkgrel=1
source=("vcs-thing::git+https://github.com/o/r.git#tag=v$pkgver" "d-$pkgver.tar.gz::https://example.org/d-$pkgver.tar.gz")
sha256sums=('SKIP' 'old')
"#,
    );
    fs::create_dir_all(dir.join("vcs-thing")).unwrap();
    fs::write(dir.join("vcs-thing/HEAD"), "not-the-archive").unwrap();
    fs::write(dir.join("d-1.1.tar.gz"), b"DD").unwrap();
    s.put("stub/git/archive.bin", b"git-archive-bytes-for-tag");

    let provider = FakeProvider::new(ProviderFamily::Arch, "1.1").with_sums(
        vec![
            ("vcs-thing", "sha256", &sha256(b"git-archive-bytes-for-tag")),
            ("d-1.1.tar.gz", "sha256", &sha256(b"DD")),
        ],
        "vcspkg",
    );
    let report = sync_arch(&dir, &provider, &s.policy());

    match &report.anchor {
        Some(AnchorOutcome::Anchored {
            anchored,
            refresh_only,
            ..
        }) => {
            assert_eq!(*anchored, 2);
            assert!(refresh_only.is_empty());
        }
        other => panic!("expected Anchored, got {other:?}"),
    }
    let log = s.log();
    assert!(
        log.contains("archive --format tar v1.1"),
        "the anchor must hash the pinned tag's archive: {log}"
    );
    assert!(
        log.contains("core.abbrev=no"),
        "git must run with core.abbrev=no like makepkg does: {log}"
    );
    // The checkout directory itself is never hashed.
    let text = read(&dir.join("PKGBUILD"));
    let sums_line = text.lines().find(|l| l.starts_with("sha256sums=")).unwrap();
    assert!(sums_line.contains("SKIP"), "a VCS entry keeps its SKIP sum");
    assert!(sums_line.contains(&sha256(b"DD")));
}

// ---------------------------------------------------------------------------
// Production Arch provider through the pacman PATH stub
// ---------------------------------------------------------------------------

/// `pacman -Si` candidates run pkgbase first, then every split pkgname
/// (`hip-runtime` builds `hip-runtime-amd`), under `LC_ALL=C`.
#[test]
fn pacman_candidate_order_pkgbase_then_pkgnames() {
    let s = Scratch::new("pacman_candidates");
    let dir = s.recipe(
        "stable",
        "hip",
        r#"pkgbase=hip
pkgname=(hip-runtime-amd)
pkgver=1.0
pkgrel=1
source=("hip.tar.gz::https://example.org/hip.tar.gz")
sha256sums=('x')
"#,
    );
    s.pacman_answer("hip-runtime-amd", "2.0-1");
    // No answer file for `hip`: pacman reports the name as unknown.

    let provider = ArchOfficial;
    let report = sync_arch(&dir, &provider, &s.policy());
    assert!(
        matches!(
            report.outcome,
            SyncOutcome::VersionMoved { ref old, ref new, .. } if old == "1.0-1" && new == "2.0-1"
        ),
        "got {:?}",
        report.outcome
    );
    let log = s.log();
    let p_lines: Vec<&str> = log.lines().filter(|l| l.starts_with("pacman ")).collect();
    assert_eq!(
        p_lines,
        vec![
            "pacman -Si hip (LC_ALL=C)",
            "pacman -Si hip-runtime-amd (LC_ALL=C)"
        ],
        "candidates must be queried pkgbase first, then split names"
    );
}
