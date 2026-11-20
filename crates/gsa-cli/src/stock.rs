//! `--with` archive resolution (contract §L.1, §E.3 2026-11-20 amendment).
//!
//! A provider whose soname moved cannot install while an installed
//! OUT-OF-TREE package still links the old soname: the only coverage an
//! in-run repair cannot give it is membership of the SAME transaction
//! (issue #6). `--with` is that membership — the operator names the stock
//! packages, and this seam resolves each name to the repo archive pacman
//! would install, so one `pacman -U` carries builder and stock bytes
//! together.
//!
//! Resolution is pacman's own truth, never a guess: `pacman -Si` names the
//! current version and architecture, the cache is `pacman-conf CacheDir`, and
//! a cache miss downloads through `sudo -n pacman -Sw`. A name that resolves
//! to nothing is a refusal — the operator asked for a transaction member the
//! transaction will not carry.

use std::path::{Path, PathBuf};
use std::process::Command;

use gsa_install::gates::{self, RepoRow};
use gsa_install::WithArchive;

/// The names in first-appearance order: `--with a,a` and `--with a --with a`
/// name ONE member, and `pacman -U` refuses a duplicate target.
fn unique(names: &[String]) -> Vec<&str> {
    let mut out: Vec<&str> = Vec::new();
    for name in names {
        if !out.contains(&name.as_str()) {
            out.push(name);
        }
    }
    out
}

/// Resolve `--with` names to their archives and read each one's
/// `.PKGINFO`. A missing archive is downloaded (the run is mutating); an
/// unreadable or absent one is a refusal, never a dropped member.
pub fn resolve(conf: Option<&str>, names: &[String]) -> Result<Vec<WithArchive>, String> {
    let names = unique(names);
    if names.is_empty() {
        return Ok(Vec::new());
    }
    let rows = repo_rows(conf, &names)?;
    let cache = cache_dir(conf);
    let mut paths: Vec<PathBuf> = Vec::new();
    let mut missing: Vec<&RepoRow> = Vec::new();
    for name in &names {
        let row = rows
            .iter()
            .find(|row| &row.name == name)
            .ok_or_else(|| format!("'--with {name}' names no repo package"))?;
        match find_archive(&cache, row) {
            Some(path) => paths.push(path),
            None => missing.push(row),
        }
    }
    if !missing.is_empty() {
        let targets: Vec<String> = missing.iter().map(|row| row.name.clone()).collect();
        download(conf, &targets)?;
        for row in missing {
            match find_archive(&cache, row) {
                Some(path) => paths.push(path),
                None => {
                    return Err(format!(
                        "'--with {}' resolved to {} ({}) but no archive is cached under {}",
                        row.name,
                        row.version,
                        row.arch,
                        cache.display()
                    ))
                }
            }
        }
    }
    let mut archives = Vec::new();
    for path in paths {
        archives.push(WithArchive::load(&path)?);
    }
    Ok(archives)
}

/// The plan-mode answer: what each name would resolve to, NEVER downloading
/// (`--dry-run` mutates nothing). A name that resolves to no repo package is
/// still an error — the plan must not promise a member that does not exist.
pub fn describe(conf: Option<&str>, names: &[String]) -> Result<Vec<String>, String> {
    let names = unique(names);
    if names.is_empty() {
        return Ok(Vec::new());
    }
    let rows = repo_rows(conf, &names)?;
    let cache = cache_dir(conf);
    let mut out = Vec::new();
    for name in &names {
        let row = rows
            .iter()
            .find(|row| &row.name == name)
            .ok_or_else(|| format!("'--with {name}' names no repo package"))?;
        let state = match find_archive(&cache, row) {
            Some(path) => path.display().to_string(),
            None => "not cached (the run downloads it)".to_string(),
        };
        out.push(format!(
            "{} {} {} {state} — joins the transaction only where the ABI gate needs it",
            row.name, row.version, row.arch
        ));
    }
    Ok(out)
}

/// The repo rows of `names` — `gsa-install`'s ONE `pacman -Si` reader, with
/// the operator's all-or-nothing policy (a `--with` member is never dropped
/// silently). `LC_ALL=C` pins the field labels there.
fn repo_rows(conf: Option<&str>, names: &[&str]) -> Result<Vec<RepoRow>, String> {
    let owned: Vec<String> = names.iter().map(|name| name.to_string()).collect();
    gates::repo_rows(conf.map(Path::new), &owned)
}

/// The cache the resolution reads: `gsa-install`'s one `pacman-conf
/// [--config CONF] CacheDir` answer, so an alternate `--config` reads ITS
/// cache rather than the host's (blind review 2026-11-20).
fn cache_dir(conf: Option<&str>) -> PathBuf {
    gsa_install::gates::pacman_cache_dir(conf.map(Path::new))
}

/// The cached archive for one repo row: the exact
/// `<name>-<version>-<arch>` archive, never a `.sig` sibling and never a
/// partial download.
fn find_archive(cache: &Path, row: &RepoRow) -> Option<PathBuf> {
    gsa_install::gates::cached_archive(cache, &row.name, &row.version, &row.arch)
}

/// Download through the same privileged path the transaction uses, so one
/// sudo policy covers both (`sudo -n`, never an interactive prompt).
fn download(conf: Option<&str>, names: &[String]) -> Result<(), String> {
    let mut cmd = Command::new("sudo");
    cmd.env("LC_ALL", "C")
        .arg("-n")
        .arg("pacman")
        .arg("-Sw")
        .arg("--noconfirm");
    if let Some(conf) = conf {
        cmd.arg("--config").arg(conf);
    }
    cmd.args(names);
    let output = cmd
        .output()
        .map_err(|e| format!("cannot run pacman -Sw: {e}"))?;
    if output.status.success() {
        return Ok(());
    }
    let stderr = String::from_utf8_lossy(&output.stderr);
    let detail = stderr
        .lines()
        .find(|line| !line.trim().is_empty())
        .unwrap_or("pacman -Sw failed");
    Err(format!(
        "cannot download --with {}: {detail}",
        names.join(" ")
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(name: &str, version: &str, arch: &str) -> RepoRow {
        RepoRow {
            name: name.to_string(),
            version: version.to_string(),
            arch: arch.to_string(),
        }
    }

    #[test]
    fn the_cache_match_is_exact_and_ignores_residue() {
        let dir = std::env::temp_dir().join(format!("gsa-stock-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let touch = |name: &str| std::fs::write(dir.join(name), b"x").unwrap();
        touch("chafa-1.14.5-1.1-x86_64.pkg.tar.zst");
        touch("chafa-1.14.5-1.1-x86_64.pkg.tar.zst.sig");
        // A partial download sorts AFTER the complete archive: an extension
        // allowlist is what keeps it out, a `.sig` blacklist is not.
        touch("chafa-1.14.5-1.1-x86_64.pkg.tar.zst.part");
        touch("chafa-1.14.4-1-x86_64.pkg.tar.zst");
        let found = find_archive(&dir, &row("chafa", "1.14.5-1.1", "x86_64")).unwrap();
        assert_eq!(
            found.file_name().unwrap().to_str().unwrap(),
            "chafa-1.14.5-1.1-x86_64.pkg.tar.zst"
        );
        // A different version is never a substitute: the transaction would
        // carry bytes the ABI gate did not judge.
        assert!(find_archive(&dir, &row("chafa", "1.14.6-1", "x86_64")).is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
