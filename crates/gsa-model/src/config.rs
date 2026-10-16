//! The `gsa.conf` config surface (plan-gsa-isolation.md W2, locked decision
//! 5; contract §J.4). Two layers, auto-read, no CLI flag:
//!
//!   `/etc/gsa.conf`                    system layer (root)
//!   `~/.config/gsa/gsa.conf`           user layer (the build user's home:
//!                                      SUDO_UID's passwd home under a sudo
//!                                      run, else `$HOME`)
//!
//! Per key the USER layer wins over the system layer, which wins over the
//! built-ins (locked decision 5). The keys are `project`, `recipe_url`,
//! `build_dir`, `state_dir`; an unknown key is an ERROR naming file:line — a
//! typo'd key must never silently mean "built-in default". The plan's fifth
//! key group ("defaults") is deliberately not implemented: the project's
//! `build-defaults.conf` already owns per-project defaults and a second
//! surface for the same knobs is a trap (2026-10-16, noted in NOTE).
//!
//! `~` at a value's start expands to the same build-user home, in either
//! file. `--state-dir` and `GSA_STATE_DIR` stay above the config layers
//! (explicit operator intent and fixture control; §J.3).

use std::path::{Path, PathBuf};

/// The built-in state root (contract §J.3).
pub const DEFAULT_STATE_DIR: &str = "/var/lib/gsa";

/// The system layer's fixed path.
pub const SYSTEM_CONFIG: &str = "/etc/gsa.conf";

/// The user layer's path below the build user's home.
pub const USER_CONFIG: &str = ".config/gsa/gsa.conf";

/// The built-in recipe-store upstream (the recipe repository's origin).
pub const DEFAULT_RECIPE_URL: &str = "https://github.com/ZhangDM-520/gentoo-style-arch.git";

/// The build-cache layout (plan-gsa-isolation.md W4): the build user's
/// `~/.cache/gsa` (config `build_dir`; `GSA_BUILD_DIR` env = fixture control
/// like `GSA_STATE_DIR`), with `build/` trees (makepkg `BUILDDIR`), `pkg/`
/// staging (`PKGDIR`) and `pkgs/` archives (`PKGDEST`) below it. Sources
/// keep honouring `makepkg.conf` `SRCDEST` untouched.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BuildLayout {
    pub root: PathBuf,
    pub builddir: PathBuf,
    pub pkgdir: PathBuf,
    pub pkgdest: PathBuf,
}

/// The build cache root: `GSA_BUILD_DIR` env > config `build_dir` > the
/// build user's `~/.cache/gsa`.
pub fn build_root(cfg: &GsaConfig) -> Result<PathBuf, String> {
    if let Ok(v) = std::env::var("GSA_BUILD_DIR") {
        if !v.trim().is_empty() {
            return Ok(PathBuf::from(v));
        }
    }
    if let Some(v) = &cfg.build_dir {
        return Ok(v.clone());
    }
    Ok(build_user_home()?.join(".cache").join("gsa"))
}

/// The full layout for a run.
pub fn build_layout(cfg: &GsaConfig) -> Result<BuildLayout, String> {
    let root = build_root(cfg)?;
    Ok(BuildLayout {
        builddir: root.join("build"),
        pkgdir: root.join("pkg"),
        pkgdest: root.join("pkgs"),
        root,
    })
}

/// The archive scan set for one recipe: the shared `PKGDEST` first, then the
/// recipe dir (the pre-W4 location — fixtures and old trees still write
/// there until the stubs flip). Every scan is `.PKGINFO`-truth filtered, so
/// a shared PKGDEST can never hand over another recipe's archive (rule 11).
pub fn archive_dirs(recipe_dir: &Path, layout: &BuildLayout) -> Vec<PathBuf> {
    let mut dirs = vec![layout.pkgdest.clone()];
    if recipe_dir != layout.pkgdest {
        dirs.push(recipe_dir.to_path_buf());
    }
    dirs
}

/// The known key roster — one place, reused by the parse error message.
const KEYS: [&str; 4] = ["project", "recipe_url", "build_dir", "state_dir"];

/// One config layer's values. `None` = the key was not set in this layer
/// (it falls through to the next layer or a built-in), never "empty".
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct GsaConfig {
    pub project: Option<PathBuf>,
    pub recipe_url: Option<String>,
    pub build_dir: Option<PathBuf>,
    pub state_dir: Option<PathBuf>,
}

impl GsaConfig {
    /// Per-key override: `over`'s set keys replace `self`'s (user > system).
    pub fn merged_with(self, over: GsaConfig) -> GsaConfig {
        GsaConfig {
            project: over.project.or(self.project),
            recipe_url: over.recipe_url.or(self.recipe_url),
            build_dir: over.build_dir.or(self.build_dir),
            state_dir: over.state_dir.or(self.state_dir),
        }
    }
}

/// Parse one layer's text. Strict: every non-comment line must be
/// `key = value` with a known key and a non-empty value; `~` at a path
/// value's start expands to `home`. `origin` names the file in errors.
pub fn parse_layer(text: &str, origin: &str, home: &Path) -> Result<GsaConfig, String> {
    let mut cfg = GsaConfig::default();
    for (idx, raw) in text.lines().enumerate() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let lineno = idx + 1;
        let Some((key, value)) = line.split_once('=') else {
            return Err(format!(
                "{origin}:{lineno}: expected 'key = value', got {line:?}"
            ));
        };
        let key = key.trim();
        let value = value.trim();
        if !KEYS.contains(&key) {
            return Err(format!(
                "{origin}:{lineno}: unknown gsa.conf key '{key}' (known: {})",
                KEYS.join(", ")
            ));
        }
        if value.is_empty() {
            return Err(format!("{origin}:{lineno}: key '{key}' has an empty value"));
        }
        match key {
            "project" => cfg.project = Some(expand_home(value, home)),
            "build_dir" => cfg.build_dir = Some(expand_home(value, home)),
            "state_dir" => cfg.state_dir = Some(expand_home(value, home)),
            "recipe_url" => cfg.recipe_url = Some(value.to_string()),
            _ => unreachable!("KEYS is the roster"),
        }
    }
    Ok(cfg)
}

/// `~`/`~/…` at the start of a path value expands to the build user's home.
/// A URL (`recipe_url`) is never passed through here.
pub fn expand_home(value: &str, home: &Path) -> PathBuf {
    if value == "~" {
        return home.to_path_buf();
    }
    if let Some(rest) = value.strip_prefix("~/") {
        return home.join(rest);
    }
    PathBuf::from(value)
}

/// `home_from_passwd` seam: the passwd home field of `uid`, from
/// `/etc/passwd`'s text. `None` when the uid has no entry.
pub fn home_from_passwd(passwd: &str, uid: u32) -> Option<PathBuf> {
    for line in passwd.lines() {
        let fields: Vec<&str> = line.split(':').collect();
        if fields.len() < 6 {
            continue;
        }
        let Ok(entry_uid) = fields[2].parse::<u32>() else {
            continue;
        };
        if entry_uid == uid && !fields[5].is_empty() {
            return Some(PathBuf::from(fields[5]));
        }
    }
    None
}

/// The build user's home: under a sudo run the SUDO_UID passwd home (the
/// user layer is the *build user's* config even though the engine is root),
/// else `$HOME`, else the passwd home of the effective uid. Errors name the
/// remedy instead of guessing a directory.
pub fn build_user_home() -> Result<PathBuf, String> {
    if let Ok(uid) = std::env::var("SUDO_UID") {
        if let Ok(uid) = uid.trim().parse::<u32>() {
            let passwd = std::fs::read_to_string("/etc/passwd")
                .map_err(|e| format!("cannot read /etc/passwd to resolve SUDO_UID's home: {e}"))?;
            if let Some(home) = home_from_passwd(&passwd, uid) {
                return Ok(home);
            }
            return Err(format!(
                "SUDO_UID={uid} has no /etc/passwd entry — run from your build user's shell"
            ));
        }
    }
    if let Ok(home) = std::env::var("HOME") {
        if !home.is_empty() {
            return Ok(PathBuf::from(home));
        }
    }
    Err("no home directory: neither SUDO_UID nor HOME is set — set HOME or run via sudo".to_string())
}

/// Load both layers, user over system over built-ins. Missing files are
/// fine (the layer simply contributes nothing); malformed files fail loud.
/// `GSA_CONF` (fixture/hermetic control, like `GSA_STATE_DIR`) replaces the
/// two auto-read layers with exactly one file.
pub fn load() -> Result<GsaConfig, String> {
    if let Ok(path) = std::env::var("GSA_CONF") {
        if !path.is_empty() {
            let home = build_user_home()?;
            return read_layer(Path::new(&path), &home);
        }
    }
    let home = build_user_home()?;
    let system = read_layer(Path::new(SYSTEM_CONFIG), &home)?;
    let user = read_layer(&home.join(USER_CONFIG), &home)?;
    Ok(system.merged_with(user))
}

fn read_layer(path: &Path, home: &Path) -> Result<GsaConfig, String> {
    let text = match std::fs::read_to_string(path) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(GsaConfig::default()),
        Err(e) => return Err(format!("cannot read {}: {e}", path.display())),
    };
    parse_layer(&text, &path.display().to_string(), home)
}

/// The state root from every layer (§J.3): explicit `--state-dir` beats
/// `GSA_STATE_DIR` beats the config layers beats the built-in. There is
/// never a silent workspace fallback.
pub fn resolve_state_dir(cli: Option<&str>) -> Result<PathBuf, String> {
    let env = std::env::var("GSA_STATE_DIR").ok();
    resolve_state_dir_from(cli, env.as_deref(), &load()?)
}

/// The pure precedence seam (testable without touching process env).
pub fn resolve_state_dir_from(
    cli: Option<&str>,
    env: Option<&str>,
    cfg: &GsaConfig,
) -> Result<PathBuf, String> {
    let nonempty = |v: &str| !v.trim().is_empty();
    if let Some(v) = cli.filter(|v| nonempty(v)) {
        return Ok(PathBuf::from(v));
    }
    if let Some(v) = env.filter(|v| nonempty(v)) {
        return Ok(PathBuf::from(v));
    }
    if let Some(v) = &cfg.state_dir {
        return Ok(v.clone());
    }
    Ok(PathBuf::from(DEFAULT_STATE_DIR))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn home() -> PathBuf {
        PathBuf::from("/home/u")
    }

    #[test]
    fn a_layer_parses_keys_comments_and_tilde() {
        let cfg = parse_layer(
            "# comment\n\nproject = ~/Projects/gsa\nrecipe_url = https://example.invalid/r.git\n\
             build_dir = /var/tmp/bd\nstate_dir = ~\n",
            "test.conf",
            &home(),
        )
        .unwrap();
        assert_eq!(cfg.project, Some(PathBuf::from("/home/u/Projects/gsa")));
        assert_eq!(
            cfg.recipe_url.as_deref(),
            Some("https://example.invalid/r.git")
        );
        assert_eq!(cfg.build_dir, Some(PathBuf::from("/var/tmp/bd")));
        assert_eq!(cfg.state_dir, Some(PathBuf::from("/home/u")));
    }

    #[test]
    fn an_unknown_key_is_an_error_naming_file_line_and_key() {
        let err = parse_layer("stat_dir = /x\n", "/etc/gsa.conf", &home()).unwrap_err();
        assert!(err.contains("/etc/gsa.conf:1"), "{err}");
        assert!(err.contains("stat_dir"), "{err}");
        assert!(err.contains("state_dir"), "{err}");
    }

    #[test]
    fn malformed_and_empty_values_are_errors() {
        assert!(parse_layer("project\n", "f", &home()).is_err());
        assert!(parse_layer("project =\n", "f", &home()).is_err());
    }

    #[test]
    fn user_layer_wins_per_key_only() {
        let system = parse_layer("state_dir = /sys\nbuild_dir = /sysb\n", "s", &home()).unwrap();
        let user = parse_layer("state_dir = /usr\n", "u", &home()).unwrap();
        let merged = system.merged_with(user);
        assert_eq!(merged.state_dir, Some(PathBuf::from("/usr")));
        assert_eq!(merged.build_dir, Some(PathBuf::from("/sysb")));
    }

    #[test]
    fn passwd_lookup_finds_the_uid_home_only() {
        let passwd = "root:x:0:0::/root:/bin/bash\n\
                      u:x:1000:1000::/home/u:/bin/bash\n";
        assert_eq!(home_from_passwd(passwd, 1000), Some(PathBuf::from("/home/u")));
        assert_eq!(home_from_passwd(passwd, 0), Some(PathBuf::from("/root")));
        assert_eq!(home_from_passwd(passwd, 42), None);
    }

    #[test]
    fn state_dir_precedence_is_cli_then_env_then_config_then_builtin() {
        let cfg = GsaConfig {
            state_dir: Some(PathBuf::from("/cfg")),
            ..GsaConfig::default()
        };
        assert_eq!(
            resolve_state_dir_from(Some("--flag"), Some("/env"), &cfg).unwrap(),
            PathBuf::from("--flag")
        );
        assert_eq!(
            resolve_state_dir_from(None, Some("/env"), &cfg).unwrap(),
            PathBuf::from("/env")
        );
        assert_eq!(
            resolve_state_dir_from(None, None, &cfg).unwrap(),
            PathBuf::from("/cfg")
        );
        assert_eq!(
            resolve_state_dir_from(None, Some("  "), &GsaConfig::default()).unwrap(),
            PathBuf::from(DEFAULT_STATE_DIR)
        );
    }
}
