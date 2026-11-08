//! Store-origin retarget (contract §B.11/§J.2): a refresh must re-point an
//! existing store's `origin` at the requested `recipe_url`. Only the
//! first-use clone honoured that URL, so repointing `DEFAULT_RECIPE_URL` (or
//! `recipe_url` in gsa.conf) kept fetching the URL the store was first
//! cloned from — silently.
//!
//! Two throwaway bare repositories stand in for "the old upstream" and "the
//! new upstream"; scratch trees live under the harness `$TMPDIR` and every
//! git child carries `GIT_CONFIG_COUNT=0` (agent shells inject git config
//! that breaks git operations). One test per process — the env pins
//! (`GSA_CONF`, `GSA_RECIPES_DIR`) are process-wide.

use std::path::{Path, PathBuf};
use std::process::Command;

use gsa_state::recipes;

fn scratch(name: &str) -> PathBuf {
    let dir =
        std::env::temp_dir().join(format!("gsa-store-retarget-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .env("GIT_CONFIG_COUNT", "0")
        .env("GIT_AUTHOR_NAME", "fixture")
        .env("GIT_AUTHOR_EMAIL", "fixture@example.invalid")
        .env("GIT_COMMITTER_NAME", "fixture")
        .env("GIT_COMMITTER_EMAIL", "fixture@example.invalid")
        .output()
        .expect("cannot run git");
    assert!(
        out.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&out.stderr).trim()
    );
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

/// One bare "upstream" with one commit; returns its clone URL and that
/// commit. `file://` keeps `--depth` meaningful (a plain path clone warns
/// and ignores it), matching what the store clone/fetch really does.
fn upstream(root: &Path, name: &str) -> (String, String) {
    let bare = root.join(format!("{name}.git"));
    let work = root.join(format!("{name}-work"));
    git(
        root,
        &[
            "init",
            "--bare",
            "--initial-branch=main",
            bare.to_str().unwrap(),
        ],
    );
    git(
        root,
        &["init", "--initial-branch=main", work.to_str().unwrap()],
    );
    std::fs::write(work.join("PKGBUILD"), format!("# {name}\n")).unwrap();
    git(&work, &["add", "."]);
    git(&work, &["commit", "-m", name]);
    git(&work, &["push", "--quiet", bare.to_str().unwrap(), "main"]);
    let head = git(&work, &["rev-parse", "HEAD"]);
    (format!("file://{}", bare.display()), head)
}

fn origin_of(store: &Path) -> String {
    git(store, &["config", "--get", "remote.origin.url"])
}

#[test]
fn refresh_retargets_the_origin_then_goes_quiet() {
    // One test, not several: the env pins below are process-wide and the
    // harness runs the tests of one binary on parallel threads.
    let root = scratch("retarget");
    let state = root.join("state");
    let store = root.join("store");
    std::fs::create_dir_all(&state).unwrap();
    // Hermetic config (GSA_CONF replaces both auto-read layers) and a pinned
    // store root (GSA_RECIPES_DIR beats recipe_dir and the built-in default).
    std::fs::write(root.join("gsa.conf"), b"").unwrap();
    std::env::set_var("GSA_CONF", root.join("gsa.conf"));
    std::env::set_var("GSA_RECIPES_DIR", &store);

    let (url_one, head_one) = upstream(&root, "one");
    let (url_two, head_two) = upstream(&root, "two");
    assert_ne!(head_one, head_two, "the two upstreams must differ");

    // (a) First use clones the store from the requested URL (unchanged path).
    let (fetched, _fetched_head) = recipes::fetch(&state, &url_one).unwrap();
    assert_eq!(fetched, store);
    assert_eq!(origin_of(&fetched), url_one);
    assert_eq!(git(&fetched, &["rev-parse", "HEAD"]), head_one);

    // (b) A refresh pointed at the second repository must follow it.
    let (head, note) = recipes::refresh(&state, &url_two).unwrap();
    assert_eq!(
        origin_of(&store),
        url_two,
        "refresh must re-point the store's origin at the requested URL"
    );
    assert_eq!(
        git(&store, &["rev-parse", "HEAD"]),
        head_two,
        "refresh must check out the NEW upstream's commit"
    );
    assert_eq!(head, head_two);
    assert_eq!(
        note.expect("a retarget must be reported to the caller"),
        format!("recipe store origin retargeted: {url_one} → {url_two}")
    );

    // (c) Idempotent: the same URL again runs the plain fetch/reset silently.
    let (head_again, note_again) = recipes::refresh(&state, &url_two).unwrap();
    assert_eq!(head_again, head_two);
    assert_eq!(note_again, None, "an agreeing origin must print nothing");

    // (d) A store with no origin at all gets one through the same seam.
    git(&store, &["remote", "remove", "origin"]);
    let (head_bare, note_bare) = recipes::refresh(&state, &url_two).unwrap();
    assert_eq!(head_bare, head_two);
    assert_eq!(origin_of(&store), url_two);
    assert_eq!(
        note_bare.expect("an added origin must be reported"),
        format!("recipe store origin retargeted: (none) → {url_two}")
    );

    // (e) An empty/blank `recipe_url` is ignored rather than written, and the
    // existing origin is used untouched.
    for blank in ["", "   "] {
        let (head_blank, note_blank) = recipes::refresh(&state, blank).unwrap();
        assert_eq!(head_blank, head_two);
        assert_eq!(
            origin_of(&store),
            url_two,
            "a blank URL must not be written"
        );
        assert_eq!(note_blank, None);
    }
}
