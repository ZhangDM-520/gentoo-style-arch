//! Dynamic IgnorePkg registration (rule 9, contract §D.1 `--install-register`):
//! an install run registers each ACCEPTED archive's `pkgbase`+`pkgname` into
//! the `[options]` `IgnorePkg` closure of the target pacman.conf before
//! `pacman -U`. An archive whose names cannot be established REFUSES
//! (fail-closed, never a silent skip).
//!
//! Mechanics (port of `lib/audit.fish` `register_ignorepkg_names`): the conf
//! is parsed exactly like pacman reads it — cumulative `IgnorePkg =` lines
//! inside `[options]` only (a line inside a repo section is silently
//! dropped, `[options]` `Include` is unfollowed); missing names are appended
//! ~10 per line at the last `IgnorePkg` line's end position inside
//! `[options]`. A dated pre-image backup `<conf>.bak-YYYYMMDD` is written
//! before the first modification of the day, never rewritten afterwards. The
//! write is atomic (temp + rename) so an interrupt never leaves a
//! half-registered closure. The bounded `db.lck` wait never deletes the lock
//! (rule 23); idleness is proven by an open-file-descriptor scan.

use std::collections::BTreeSet;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use gsa_recipe::pkginfo::Pkginfo;

/// What one registration write did.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RegisterReport {
    /// Names actually added to the closure (sorted).
    pub added: Vec<String>,
    /// The dated pre-image backup written, if the conf was modified.
    pub backup: Option<PathBuf>,
    /// True when the step was skipped loudly (`--no-register-ignorepkg`).
    pub skipped: bool,
}

/// Establish one archive's registration names (rule 9, authority order):
/// the archive's own `.PKGINFO` `pkgbase`+`pkgname`, else the recipe
/// directory beside the archive (committed `.SRCINFO` pkgbase+pkgname).
/// No authority answers → `Err` — the caller refuses (fail-closed).
pub fn names_for_archive(
    pkginfo: Option<&Pkginfo>,
    recipe_dir: Option<&Path>,
) -> Result<Vec<String>, String> {
    let mut names: Vec<String> = Vec::new();
    if let Some(info) = pkginfo {
        for name in [&info.pkgbase, &info.pkgname] {
            if !names.contains(name) {
                names.push(name.clone());
            }
        }
        return Ok(names);
    }
    if let Some(dir) = recipe_dir {
        let srcinfo = dir.join(".SRCINFO");
        if let Ok(text) = std::fs::read_to_string(&srcinfo) {
            let origin = srcinfo.to_string_lossy().into_owned();
            if let Ok(parsed) = gsa_recipe::parse_srcinfo(&text, &origin) {
                if let Some(base) = parsed.pkgbase {
                    names.push(base);
                }
                for name in parsed.pkgnames {
                    if !names.contains(&name) {
                        names.push(name);
                    }
                }
                if !names.is_empty() {
                    return Ok(names);
                }
            }
        }
    }
    let where_ = match recipe_dir {
        Some(dir) => dir.display().to_string(),
        None => "(no recipe directory)".to_string(),
    };
    Err(format!(
        "install-register: cannot establish the package names — no readable .PKGINFO and no pkgbase/pkgname in {where_}"
    ))
}

/// Where new `IgnorePkg =` lines land inside `[options]` (fish
/// `pacman_conf_ignorepkg_walk`'s splice point).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Insert {
    /// Right after this 1-based line (the last `IgnorePkg` line's end).
    AfterLine(usize),
    /// Before this 1-based line (the first section header after
    /// `[options]`, so the lines stay inside `[options]`).
    BeforeLine(usize),
    /// End of file, newline-guarded.
    Append,
}

#[derive(Debug, Default)]
struct ConfWalk {
    /// The cumulative `[options]` closure.
    ignored: BTreeSet<String>,
    /// `IgnorePkg` lines inside repo sections (dropped by pacman — warn).
    repo_drops: Vec<(usize, String)>,
    /// `Include` lines inside `[options]` (closure unfollowable — warn).
    options_includes: Vec<usize>,
    insert: Option<Insert>,
    has_options: bool,
}

/// Parse the target conf exactly like pacman reads it: cumulative
/// `IgnorePkg =` lines inside `[options]` ONLY (a line inside a repo section
/// is dropped with a warning; `[options]` `Include` is unfollowed).
fn walk_conf(text: &str) -> ConfWalk {
    let mut walk = ConfWalk::default();
    let mut in_options = false;
    let mut section = String::new();
    let mut last_ignore: usize = 0;
    let mut insert_before: usize = 0;
    for (idx, raw_line) in text.lines().enumerate() {
        let line_no = idx + 1;
        let line = raw_line.split('#').next().unwrap_or("").trim();
        if line.is_empty() {
            continue;
        }
        if line.starts_with('[') && line.ends_with(']') && line.len() >= 2 {
            section = line[1..line.len() - 1].trim().to_string();
            if section == "options" {
                in_options = true;
                walk.has_options = true;
            } else {
                if walk.has_options && insert_before == 0 {
                    insert_before = line_no;
                }
                in_options = false;
            }
            continue;
        }
        if line.starts_with("IgnorePkg")
            && line.split('=').next().unwrap_or("").trim() == "IgnorePkg"
        {
            if in_options {
                last_ignore = line_no;
                if let Some((_, values)) = line.split_once('=') {
                    for name in values.split_whitespace() {
                        walk.ignored.insert(name.to_string());
                    }
                }
            } else if !section.is_empty() {
                walk.repo_drops.push((line_no, section.clone()));
            }
            continue;
        }
        if in_options && line.starts_with("Include") {
            walk.options_includes.push(line_no);
        }
    }
    walk.insert = if !walk.has_options {
        None
    } else if last_ignore > 0 {
        Some(Insert::AfterLine(last_ignore))
    } else if insert_before > 0 {
        Some(Insert::BeforeLine(insert_before))
    } else {
        Some(Insert::Append)
    };
    walk
}

/// Dated pre-image backup suffix (`YYYYMMDD`, LOCAL date — the day boundary
/// is the host's, like fish `date +%Y%m%d`). `date` is the authority; a UTC
/// civil-date computation is the fallback when it cannot run.
fn date_tag() -> String {
    if let Ok(output) = Command::new("date").arg("+%Y%m%d").output() {
        if output.status.success() {
            let tag = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if tag.len() == 8 && tag.bytes().all(|b| b.is_ascii_digit()) {
                return tag;
            }
        }
    }
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let days = secs.div_euclid(86_400);
    // Civil-from-days (Howard Hinnant's algorithm), UTC.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!("{y:04}{m:02}{d:02}")
}

/// Does some live process hold this lock file open? Idleness is proven by an
/// open-file-descriptor scan over `/proc/*/fd` (gsa-sched::lock
/// `pacman_lock_probe`'s technique), never by filenames and never by
/// deleting `db.lck` (rule 23).
fn lock_has_live_holder(lock: &Path) -> bool {
    let Ok(meta) = std::fs::metadata(lock) else {
        return false;
    };
    let ino = meta.ino();
    let dev = meta.dev();
    let Ok(proc_dir) = std::fs::read_dir("/proc") else {
        // Cannot scan: treat as held (do not proceed on unproven idleness).
        return true;
    };
    for entry in proc_dir.flatten() {
        let Ok(pid) = entry.file_name().to_string_lossy().parse::<i32>() else {
            continue;
        };
        if pid == std::process::id() as i32 {
            continue;
        }
        let Ok(fds) = std::fs::read_dir(format!("/proc/{pid}/fd")) else {
            continue;
        };
        for fd in fds.flatten() {
            if let Ok(target) = std::fs::metadata(fd.path()) {
                if target.ino() == ino && target.dev() == dev {
                    return true;
                }
            }
        }
    }
    false
}

/// Bounded `db.lck` wait (rule 9/23): a held lock is polled (1s) until it
/// clears, up to 300s; a stale lock (no live holder) proceeds loudly and is
/// NEVER touched. Timeout → `Err` (the install refuses).
fn wait_for_db_lock(db_root: &Path) -> Result<(), String> {
    let lock = db_root.join("db.lck");
    let deadline = Instant::now() + Duration::from_secs(300);
    let mut waiting = false;
    loop {
        if !lock.exists() {
            return Ok(());
        }
        if !lock_has_live_holder(&lock) {
            eprintln!(
                "gsa: note: stale db.lck at {} (no live holder) — proceeding without touching it",
                lock.display()
            );
            return Ok(());
        }
        if !waiting {
            waiting = true;
            eprintln!(
                "gsa: note: waiting for the pacman database lock to clear ({}) — never deleting it",
                lock.display()
            );
        }
        if Instant::now() >= deadline {
            return Err(format!(
                "register-ignorepkg: {} is still held after 300s — refusing to install unregistered package name(s)",
                lock.display()
            ));
        }
        std::thread::sleep(Duration::from_secs(1));
    }
}

/// Insert `new_lines` into the conf text at the walk's splice point.
fn splice(text: &str, insert: Insert, new_lines: &[String]) -> String {
    let mut out = String::new();
    match insert {
        Insert::AfterLine(n) => {
            for (idx, line) in text.lines().enumerate() {
                out.push_str(line);
                out.push('\n');
                if idx + 1 == n {
                    for new in new_lines {
                        out.push_str(new);
                        out.push('\n');
                    }
                }
            }
        }
        Insert::BeforeLine(n) => {
            for (idx, line) in text.lines().enumerate() {
                if idx + 1 == n {
                    for new in new_lines {
                        out.push_str(new);
                        out.push('\n');
                    }
                }
                out.push_str(line);
                out.push('\n');
            }
        }
        Insert::Append => {
            out.push_str(text);
            if !text.ends_with('\n') && !text.is_empty() {
                out.push('\n');
            }
            for new in new_lines {
                out.push_str(new);
                out.push('\n');
            }
        }
    }
    out
}

fn run_sudo(args: &[&str]) -> Result<(), String> {
    let output = Command::new("sudo")
        .arg("-n")
        .args(args)
        .output()
        .map_err(|e| format!("cannot run sudo: {e}"))?;
    if output.status.success() {
        Ok(())
    } else {
        Err(format!(
            "sudo -n {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&output.stderr).trim()
        ))
    }
}

/// The registration write path (the `--install-register` seam and the
/// install-run step share it): bounded `db.lck` wait (holder scan, never
/// deletion), parse the closure, add `names`, atomic rewrite, dated backup.
/// A wait timeout or write failure is `Err` — the install refuses before any
/// transaction runs.
pub fn register_ignorepkg(
    conf: &Path,
    subject: &str,
    names: &[String],
    db_root: &Path,
) -> Result<RegisterReport, String> {
    let text = std::fs::read_to_string(conf).map_err(|e| {
        format!(
            "register-ignorepkg: cannot read {} ({e}) — nothing changed",
            conf.display()
        )
    })?;
    let walk = walk_conf(&text);
    for (line_no, section) in &walk.repo_drops {
        eprintln!(
            "register-ignorepkg: warning: {} line {line_no}: IgnorePkg inside repo section [{section}] is dropped by pacman — move it into [options]",
            conf.display()
        );
    }
    for line_no in &walk.options_includes {
        eprintln!(
            "register-ignorepkg: warning: {} line {line_no}: [options] Include is not followed — inline its IgnorePkg entries into the file",
            conf.display()
        );
    }
    let insert = match walk.insert {
        Some(insert) => insert,
        None => {
            return Err(format!(
                "register-ignorepkg: {}: no [options] section — IgnorePkg lines have nowhere to live — nothing changed",
                conf.display()
            ))
        }
    };

    // Missing names: the sorted set difference (given − closure).
    let mut wanted: Vec<String> = names.to_vec();
    wanted.sort();
    wanted.dedup();
    let missing: Vec<String> = wanted
        .iter()
        .filter(|n| !walk.ignored.contains(*n))
        .cloned()
        .collect();
    if missing.is_empty() {
        // Post-condition holds by construction (nothing to append).
        return Ok(RegisterReport {
            added: Vec::new(),
            backup: None,
            skipped: false,
        });
    }

    // The conf rewrite is deferred until the pacman database lock clears.
    wait_for_db_lock(db_root)?;

    // Dated pre-image backup before the first modification of the day;
    // never rewritten — a differing one is kept as the day's pre-image.
    let backup = PathBuf::from(format!("{}.bak-{}", conf.display(), date_tag()));
    let need_sudo = !is_writable_dir(conf.parent().unwrap_or(Path::new(".")));
    if backup.exists() {
        let identical = std::fs::read(&backup)
            .map(|b| b == std::fs::read(conf).unwrap_or_default())
            .unwrap_or(false);
        if identical {
            eprintln!(
                "register-ignorepkg: backup {} already present (identical pre-image)",
                backup.display()
            );
        } else {
            eprintln!(
                "register-ignorepkg: backup {} already present (kept as the day's pre-image)",
                backup.display()
            );
        }
    } else if need_sudo {
        run_sudo(&[
            "cp",
            "-p",
            "--",
            &conf.display().to_string(),
            &backup.display().to_string(),
        ])
        .map_err(|e| {
            format!(
                "register-ignorepkg: cannot write backup {} — nothing changed ({e})",
                backup.display()
            )
        })?;
        eprintln!(
            "register-ignorepkg: backup {} (pre-image)",
            backup.display()
        );
    } else {
        std::fs::copy(conf, &backup).map_err(|e| {
            format!(
                "register-ignorepkg: cannot write backup {} — nothing changed ({e})",
                backup.display()
            )
        })?;
        eprintln!(
            "register-ignorepkg: backup {} (pre-image)",
            backup.display()
        );
    }

    // ~10 names per cumulative `IgnorePkg =` line, in sorted order.
    let mut new_lines: Vec<String> = Vec::new();
    for chunk in missing.chunks(10) {
        new_lines.push(format!("IgnorePkg = {}", chunk.join(" ")));
    }
    let new_text = splice(&text, insert, &new_lines);

    // Atomicity: write a temp file in the conf's directory and rename(2)
    // over the conf — a SIGINT mid-write never leaves a half-registered
    // closure. Non-writable targets escalate with `sudo -n` only.
    let tmp_name = format!(".gsa-ignorepkg.tmp.{}", std::process::id());
    let tmp_path = conf.parent().unwrap_or(Path::new(".")).join(&tmp_name);
    if need_sudo {
        // The conf's directory needs root: stage the content where the user
        // can write, then `sudo -n install` + `sudo -n mv` it into place.
        let staging =
            std::env::temp_dir().join(format!("gsa-ignorepkg.stage.{}", std::process::id()));
        std::fs::write(&staging, &new_text).map_err(|e| {
            let _ = std::fs::remove_file(&staging);
            format!("register-ignorepkg: cannot stage the rewrite — nothing changed ({e})")
        })?;
        let mode = std::fs::metadata(conf)
            .map(|m| format!("{:o}", m.permissions().mode() & 0o7777))
            .unwrap_or_else(|_| "644".to_string());
        let result = run_sudo(&[
            "install",
            "-m",
            &mode,
            "--",
            &staging.display().to_string(),
            &tmp_path.display().to_string(),
        ])
        .and_then(|_| {
            run_sudo(&[
                "mv",
                "-f",
                "--",
                &tmp_path.display().to_string(),
                &conf.display().to_string(),
            ])
        });
        let _ = std::fs::remove_file(&staging);
        if let Err(e) = result {
            let _ = run_sudo(&["rm", "-f", "--", &tmp_path.display().to_string()]);
            return Err(format!(
                "register-ignorepkg: cannot write {} — nothing changed ({e})",
                conf.display()
            ));
        }
    } else {
        let write =
            std::fs::write(&tmp_path, &new_text).and_then(|_| std::fs::rename(&tmp_path, conf));
        if let Err(e) = write {
            let _ = std::fs::remove_file(&tmp_path);
            return Err(format!(
                "register-ignorepkg: cannot write {} — nothing changed ({e})",
                conf.display()
            ));
        }
    }

    // Post-condition: re-parse through the same walker; the write only
    // counts when the closure it ships is provably complete.
    let after = walk_conf(&std::fs::read_to_string(conf).map_err(|e| {
        format!(
            "register-ignorepkg: cannot re-read {} after the write ({e})",
            conf.display()
        )
    })?);
    let still_missing: Vec<String> = wanted
        .iter()
        .filter(|n| !after.ignored.contains(*n))
        .cloned()
        .collect();
    if !still_missing.is_empty() {
        return Err(format!(
            "register-ignorepkg: verification failed — {} not covered after the write",
            still_missing.join(", ")
        ));
    }
    eprintln!(
        "register-ignorepkg: {subject}, appended {} name(s) as {} IgnorePkg line(s)",
        missing.len(),
        new_lines.len()
    );
    Ok(RegisterReport {
        added: missing,
        backup: Some(backup),
        skipped: false,
    })
}

fn is_writable_dir(dir: &Path) -> bool {
    let probe = dir.join(format!(".gsa-write-probe.{}", std::process::id()));
    let writable = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&probe)
        .is_ok();
    if writable {
        let _ = std::fs::remove_file(&probe);
    }
    writable
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn scratch(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("gsa-register-test-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("db")).unwrap();
        dir
    }

    fn names(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn registration_lands_inside_options_and_backs_up_once() {
        let dir = scratch("write");
        let conf = dir.join("pacman.conf");
        fs::write(
            &conf,
            "[options]\nHoldPkg = pacman\nIgnorePkg = already\n\n[core]\nInclude = /etc/pacman.d/mirrorlist\nIgnorePkg = droppped-in-repo\n",
        )
        .unwrap();
        let db = dir.join("db");

        let report = register_ignorepkg(
            &conf,
            "2 name(s) from 1 archive(s)",
            &names(&["foo", "foo-docs"]),
            &db,
        )
        .unwrap();
        assert_eq!(report.added, names(&["foo", "foo-docs"]));
        let backup = report.backup.clone().unwrap();
        assert!(backup.exists());
        let backup_first = fs::read(&backup).unwrap();

        let text = fs::read_to_string(&conf).unwrap();
        // Cumulative lines land inside [options], after the last IgnorePkg.
        let options_end = text.find("[core]").unwrap();
        let inserted = text.find("IgnorePkg = foo foo-docs").unwrap();
        assert!(inserted < options_end);
        assert!(text.find("IgnorePkg = already").unwrap() < inserted);
        // The repo-section line stayed untouched (dropped by pacman).
        assert!(text.contains("IgnorePkg = droppped-in-repo"));

        // Idempotent second call: nothing added, backup never rewritten.
        let report2 =
            register_ignorepkg(&conf, "again", &names(&["foo", "foo-docs"]), &db).unwrap();
        assert!(report2.added.is_empty());
        assert!(report2.backup.is_none());
        assert_eq!(fs::read(&backup).unwrap(), backup_first);

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn registration_appends_newline_guarded_and_chunks_ten() {
        let dir = scratch("append");
        let conf = dir.join("pacman.conf");
        fs::write(&conf, "[options]\nHoldPkg = pacman").unwrap();
        let db = dir.join("db");
        let many: Vec<String> = (0..12).map(|i| format!("pkg{i}")).collect();
        register_ignorepkg(&conf, "12 names", &many, &db).unwrap();
        let text = fs::read_to_string(&conf).unwrap();
        assert!(text.ends_with('\n'));
        let lines: Vec<&str> = text.lines().collect();
        let ignore_lines: Vec<&&str> = lines
            .iter()
            .filter(|l| l.starts_with("IgnorePkg = "))
            .collect();
        assert_eq!(ignore_lines.len(), 2);
        assert_eq!(ignore_lines[0].split_whitespace().count() - 2, 10);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn registration_refuses_without_options_and_tolerates_a_stale_lock() {
        let dir = scratch("refuse");
        let conf = dir.join("pacman.conf");
        fs::write(&conf, "[core]\nServer = example\n").unwrap();
        let db = dir.join("db");
        let err = register_ignorepkg(&conf, "x", &names(&["foo"]), &db).unwrap_err();
        assert!(err.contains("no [options] section"));
        assert_eq!(
            fs::read_to_string(&conf).unwrap(),
            "[core]\nServer = example\n"
        );

        // A stale db.lck with no live holder proceeds loudly, untouched.
        let conf2 = dir.join("pacman2.conf");
        fs::write(&conf2, "[options]\n").unwrap();
        let lock = db.join("db.lck");
        fs::write(&lock, "").unwrap();
        register_ignorepkg(&conf2, "x", &names(&["foo"]), &db).unwrap();
        assert!(lock.exists());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn names_for_archive_walks_the_authority_ladder() {
        use gsa_recipe::pkginfo::Pkginfo;
        let info = Pkginfo {
            pkgbase: "foo".to_string(),
            pkgname: "foo-docs".to_string(),
            version: "0:1-1".to_string(),
            provides: Vec::new(),
            depends: Vec::new(),
            arch: "any".to_string(),
        };
        assert_eq!(
            names_for_archive(Some(&info), None).unwrap(),
            names(&["foo", "foo-docs"])
        );

        let dir = scratch("names");
        let recipe = dir.join("recipe");
        fs::create_dir_all(&recipe).unwrap();
        fs::write(
            recipe.join(".SRCINFO"),
            "pkgbase = bar\npkgname = bar\npkgname = bar-docs\n",
        )
        .unwrap();
        assert_eq!(
            names_for_archive(None, Some(&recipe)).unwrap(),
            names(&["bar", "bar-docs"])
        );

        let empty = dir.join("empty");
        fs::create_dir_all(&empty).unwrap();
        assert!(names_for_archive(None, Some(&empty)).is_err());
        let _ = fs::remove_dir_all(&dir);
    }
}
