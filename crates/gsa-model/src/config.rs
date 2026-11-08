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
//! `build_dir`, `state_dir`, `recipe_dir`; an unknown key is an ERROR naming
//! file:line — a typo'd key must never silently mean "built-in default". The plan's fifth
//! key group ("defaults") is deliberately not implemented: the project's
//! `build-defaults.conf` already owns per-project defaults and a second
//! surface for the same knobs is a trap (2026-10-16, noted in NOTE).
//!
//! `~` at a value's start expands to the same build-user home, in either
//! file. `--state-dir` and `GSA_STATE_DIR` stay above the config layers
//! (explicit operator intent and fixture control; §J.3).
//!
//! Four settings resolve through one ladder (`resolve` below): the build root
//! (§J.2), the state root (§J.3), the recipe store and the makepkg `SRCDEST`.
//! Each rung carries the label its surfaces show, so "where did this value
//! come from?" has one answer per setting and no surface re-derives the
//! precedence by hand.

use std::path::{Path, PathBuf};
use std::sync::OnceLock;

/// The run-scoped build-root choice (contract §J.2): `--build-dir` or the
/// interactive answer. Set once, before any layout resolves, and above the
/// environment on purpose — a lane child that re-resolves the layout must
/// land on the same tree as its supervisor.
static BUILD_ROOT_OVERRIDE: OnceLock<PathBuf> = OnceLock::new();

/// The built-in state root (contract §J.3).
pub const DEFAULT_STATE_DIR: &str = "/var/lib/gsa";

/// The system layer's fixed path.
pub const SYSTEM_CONFIG: &str = "/etc/gsa.conf";

/// The user layer's path below the build user's home.
pub const USER_CONFIG: &str = ".config/gsa/gsa.conf";

/// The built-in recipe-store upstream (the recipe repository's origin).
pub const DEFAULT_RECIPE_URL: &str = "https://github.com/ZhangDM-520/gentoo-style-arch.git";

/// The shared "no recipe workspace found" remedy. One string, one home:
/// every user-visible not-found path renders this same clause (the CLI's
/// discovery errors and the topology loader's not-found error alike) — the
/// retired cwd-only advice taught a workflow the store replaced.
pub const WORKSPACE_HINT: &str =
    "set `project` in gsa.conf, run inside the recipe repository, or fetch the store with `sudo gsa -Sy`";

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

/// One value plus the rung of its ladder that decided it. The label is the
/// user-visible provenance (the build-dir prompt renders it as
/// `current: <path>  [gsa.conf build_dir]`), so it must name where the value
/// came from, not what it is.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Resolved<T> {
    value: T,
    source: &'static str,
}

/// The ONE resolution ladder: rungs are ordered highest precedence first and
/// the first `Some` wins, its label becoming the provenance of the result.
/// `default` is a closure because the built-in rung can itself fail (no
/// resolvable build-user home) and must stay unevaluated when a higher rung
/// already answered — an explicit override never fails on identity home
/// resolution.
fn resolve<T: Clone>(
    tiers: &[(&'static str, Option<T>)],
    default: impl FnOnce() -> Result<(T, &'static str), String>,
) -> Result<Resolved<T>, String> {
    match resolve_opt(tiers) {
        Some(resolved) => Ok(resolved),
        None => default().map(|(value, source)| Resolved { value, source }),
    }
}

/// The same ladder for a setting whose "unset" is a real answer (`SRCDEST`):
/// `None` means no rung supplied a value, and the caller names that case.
fn resolve_opt<T: Clone>(tiers: &[(&'static str, Option<T>)]) -> Option<Resolved<T>> {
    tiers.iter().find_map(|(source, value)| {
        value.as_ref().map(|value| Resolved {
            value: value.clone(),
            source,
        })
    })
}

/// A blank environment value is "unset" — the convention the `GSA_*`
/// inputs share (`GSA_BUILD_DIR`, `GSA_STATE_DIR`, `GSA_RECIPES_DIR`): a
/// whitespace-only override never means the empty path. `SRCDEST` keeps its
/// own stricter rule (only a truly empty value is unset).
fn nonempty(value: Option<&str>) -> Option<&str> {
    value.filter(|v| !v.trim().is_empty())
}

/// One `GSA_*` path input, when it is set and non-empty.
fn env_path(name: &str) -> Option<PathBuf> {
    nonempty(std::env::var(name).ok().as_deref()).map(PathBuf::from)
}

/// The build cache root, highest precedence first: the run-scoped override
/// ([`set_build_root_override`] — `--build-dir` or the prompt's answer), the
/// `GSA_BUILD_DIR` environment input, the config `build_dir` key, then the
/// build user's `~/.cache/gsa`.
pub fn build_root(cfg: &GsaConfig) -> Result<PathBuf, String> {
    build_root_with_source(cfg).map(|(root, _)| root)
}

/// [`build_root`] plus the tier that decided it — the prompt names its
/// current value's provenance so an operator can tell a gsa.conf default
/// from a stray environment override.
pub fn build_root_with_source(cfg: &GsaConfig) -> Result<(PathBuf, &'static str), String> {
    let resolved = resolve(
        &[
            ("this run's choice", BUILD_ROOT_OVERRIDE.get().cloned()),
            ("GSA_BUILD_DIR", env_build_root()),
            ("gsa.conf build_dir", cfg.build_dir.clone()),
        ],
        || {
            Ok((
                build_user_home()?.join(".cache").join("gsa"),
                "the built-in default",
            ))
        },
    )?;
    Ok((resolved.value, resolved.source))
}

/// Pin the run's build root (contract §J.2). Called once, by the CLI, before
/// the first layout resolution; a later call is ignored so a lane child can
/// never repoint the tree mid-run.
pub fn set_build_root_override(root: PathBuf) {
    if root.as_os_str().is_empty() {
        return;
    }
    let _ = BUILD_ROOT_OVERRIDE.set(root);
}

/// Whether the run pinned a build root ([`set_build_root_override`]).
pub fn build_root_override() -> Option<&'static Path> {
    BUILD_ROOT_OVERRIDE.get().map(PathBuf::as_path)
}

/// The `GSA_BUILD_DIR` environment input, when it is set and non-empty.
pub fn env_build_root() -> Option<PathBuf> {
    env_path("GSA_BUILD_DIR")
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

/// The run's build layout under the engine's ONE error policy: a failure is
/// fatal for the operation that asked, with this message — never a silent
/// degrade to legacy in-recipe `src/`/`pkg/`/archive trees (contract §J.3
/// has no silent fallback; 2026-10-17 sweep: three call sites each chose
/// their own swallow and the build landed where discovery only looks by
/// legacy fallback).
pub fn build_layout_for_run() -> Result<BuildLayout, String> {
    load().and_then(|c| build_layout(&c)).map_err(|err| {
        format!(
            "the build-cache layout is unusable ({err}); refusing to fall back to recipe-dir trees"
        )
    })
}

/// The live source-tree dir makepkg compiles one pkgbase in (§J.2):
/// `<build_dir>/<pkgbase>/src` — the home of every built-from checkout
/// since W4a, never the recipe dir.
pub fn build_tree_srcdir(layout: &BuildLayout, pkgbase: &str) -> PathBuf {
    layout.builddir.join(pkgbase).join("src")
}

/// Where one recipe's VCS checkouts may live, in probe order — the live
/// homes first: the W4a [`build_tree_srcdir`] scoped to this recipe's
/// pkgbase, then the pre-W4a roots beside the recipe (old trees persist),
/// then the resolved `SRCDEST` mirror when `srcdest` is given.
///
/// A mirror tier is passed only by ref-addressed recomputation (`git
/// archive <ref>`): a mirror's HEAD is the remote's default branch, never
/// the built ref, so revision probing must not consult it. A scoped root
/// miss fails closed rather than falling back to another pkgbase's tree —
/// a same-named checkout there is someone else's evidence (2026-10-17
/// sweep; the 2026-10-16 stopgap scanned every tree).
pub fn checkout_roots_in(
    recipe_dir: &Path,
    pkgbase: Option<&str>,
    layout: &BuildLayout,
    srcdest: Option<&Path>,
) -> Vec<PathBuf> {
    let mut roots = Vec::new();
    match pkgbase {
        Some(base) => roots.push(build_tree_srcdir(layout, base)),
        None => {
            // pkgbase unknown (nothing to scope by): every tree stands in
            // for the scoped root — the old stopgap, kept only for this
            // degraded case.
            let mut trees: Vec<PathBuf> = match std::fs::read_dir(&layout.builddir) {
                Ok(entries) => entries.flatten().map(|e| e.path().join("src")).collect(),
                Err(_) => Vec::new(),
            };
            trees.sort();
            roots.extend(trees);
        }
    }
    roots.push(recipe_dir.join("src"));
    roots.push(recipe_dir.to_path_buf());
    if let Some(srcdest) = srcdest {
        roots.push(srcdest.to_path_buf());
    }
    roots
}

/// [`checkout_roots_in`] with the process-resolved layout and SRCDEST
/// (`include_mirror` gates the mirror tier exactly as above). A
/// layout-resolution failure degrades to the legacy roots only — the
/// caller's lookup then simply finds nothing in the cache, which fails
/// closed at its own seam.
pub fn checkout_roots(recipe_dir: &Path, pkgbase: Option<&str>, include_mirror: bool) -> Vec<PathBuf> {
    let srcdest = if include_mirror { resolve_srcdest() } else { None };
    match load().and_then(|c| build_layout(&c)) {
        Ok(layout) => checkout_roots_in(recipe_dir, pkgbase, &layout, srcdest.as_deref()),
        Err(_) => {
            let mut roots = vec![recipe_dir.join("src"), recipe_dir.to_path_buf()];
            if let Some(srcdest) = srcdest {
                roots.push(srcdest);
            }
            roots
        }
    }
}

/// The known key roster — one place, reused by the parse error message.
const KEYS: [&str; 5] = [
    "project",
    "recipe_url",
    "build_dir",
    "state_dir",
    "recipe_dir",
];

/// One config layer's values. `None` = the key was not set in this layer
/// (it falls through to the next layer or a built-in), never "empty".
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct GsaConfig {
    pub project: Option<PathBuf>,
    pub recipe_url: Option<String>,
    pub build_dir: Option<PathBuf>,
    pub state_dir: Option<PathBuf>,
    pub recipe_dir: Option<PathBuf>,
}

impl GsaConfig {
    /// Per-key override: `over`'s set keys replace `self`'s (user > system).
    pub fn merged_with(self, over: GsaConfig) -> GsaConfig {
        GsaConfig {
            project: over.project.or(self.project),
            recipe_url: over.recipe_url.or(self.recipe_url),
            build_dir: over.build_dir.or(self.build_dir),
            state_dir: over.state_dir.or(self.state_dir),
            recipe_dir: over.recipe_dir.or(self.recipe_dir),
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
            "recipe_dir" => cfg.recipe_dir = Some(expand_home(value, home)),
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

/// The makepkg `SRCDEST` of the build domain: the `SRCDEST` env (explicit
/// and fixture control) beats the BUILD USER's `~/.makepkg.conf` beats
/// `/etc/makepkg.conf`. Engine-side lookups must resolve through this, never
/// the raw env alone — under a root supervisor `SRCDEST` is not in the
/// environment at all and lives in the user's makepkg.conf (2026-10-16
/// smoke: the checkout was invisible and the anchor deferred
/// source-unfetchable), and `$HOME` there is root's (same
/// identity-follows-the-drop rule as `privilege::drop_identity_env`).
pub fn resolve_srcdest() -> Option<PathBuf> {
    resolve_srcdest_with_source().0
}

/// [`resolve_srcdest`] plus the rung that decided it; `"no SRCDEST"` when no
/// tier supplied one (the callers' `None` branch, unchanged). Both conf files
/// are read up front (two small local files); which one decides the value is
/// the ladder's answer, never the read order.
pub fn resolve_srcdest_with_source() -> (Option<PathBuf>, &'static str) {
    // The home the conf's shell would expand against is the BUILD USER's
    // (same identity-follows-the-drop rule as `privilege::drop_identity_env`).
    let home = build_user_home().ok();
    let user_conf = home
        .as_ref()
        .and_then(|home| std::fs::read_to_string(home.join(".makepkg.conf")).ok());
    let system_conf = std::fs::read_to_string("/etc/makepkg.conf").ok();
    let env = std::env::var("SRCDEST").ok();
    let resolved = resolve_srcdest_from(
        env.as_deref(),
        user_conf.as_deref(),
        system_conf.as_deref(),
        home.as_deref(),
    );
    (resolved.value, resolved.source)
}

/// The pure precedence seam for [`resolve_srcdest`]: both conf files arrive
/// as text and `home` expands their home-relative shapes, so the ladder is
/// testable without touching the process environment or the filesystem.
fn resolve_srcdest_from(
    env: Option<&str>,
    user_conf: Option<&str>,
    system_conf: Option<&str>,
    home: Option<&Path>,
) -> Resolved<Option<PathBuf>> {
    let from_conf = |text: Option<&str>| {
        text.and_then(|text| makepkg_conf_assign(text, "SRCDEST"))
            .map(|dir| expand_home_path(&dir, home))
    };
    match resolve_opt(&[
        // SRCDEST's own convention is stricter than the `GSA_*` inputs':
        // only a truly empty value is unset.
        ("SRCDEST", env.filter(|v| !v.is_empty()).map(PathBuf::from)),
        ("~/.makepkg.conf SRCDEST", from_conf(user_conf)),
        ("/etc/makepkg.conf SRCDEST", from_conf(system_conf)),
    ]) {
        Some(resolved) => Resolved {
            value: Some(resolved.value),
            source: resolved.source,
        },
        None => Resolved {
            value: None,
            source: "no SRCDEST",
        },
    }
}

/// Makepkg.conf is shell and a path-valued key realistically takes the two
/// home-relative shapes expanded here (`~`, `$HOME`/`${HOME}`); anything
/// else (command substitution, `include` directives) stays literal — the
/// approximate parse is documented behaviour, and a dropped
/// `bash -c 'source <conf>'` adapter is the honest future seam (2026-10-17
/// sweep).
fn expand_home_path(value: &str, home: Option<&Path>) -> PathBuf {
    let Some(home) = home else {
        return PathBuf::from(value);
    };
    if value == "~" {
        return home.to_path_buf();
    }
    for prefix in ["~/", "$HOME/", "${HOME}/"] {
        if let Some(rest) = value.strip_prefix(prefix) {
            return home.join(rest);
        }
    }
    PathBuf::from(value)
}

/// One `NAME=value` assignment from a makepkg.conf-shaped file (comments and
/// shell quoting tolerated enough for the path-valued keys we read). Shell
/// semantics: a LATER assignment wins — the 2026-10-17 sweep found the scan
/// returning the first, resolving a different path than makepkg uses.
fn makepkg_conf_assign(content: &str, name: &str) -> Option<String> {
    let mut found = None;
    for raw in content.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        if key.trim() != name {
            continue;
        }
        let value = value.trim().trim_matches(|c| c == '"' || c == '\'');
        if !value.is_empty() {
            found = Some(value.to_string());
        }
    }
    found
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
    resolve_state_dir_with_source(cli).map(|(dir, _)| dir)
}

/// [`resolve_state_dir`] plus the rung that decided it (`--state-dir`,
/// `GSA_STATE_DIR`, `gsa.conf state_dir`, `the built-in default`) — one
/// answer for the surfaces that report why a run owns the root it owns.
pub fn resolve_state_dir_with_source(cli: Option<&str>) -> Result<(PathBuf, &'static str), String> {
    let env = std::env::var("GSA_STATE_DIR").ok();
    resolve_state_dir_from(cli, env.as_deref(), &load()?)
}

/// The pure precedence seam (testable without touching process env).
pub fn resolve_state_dir_from(
    cli: Option<&str>,
    env: Option<&str>,
    cfg: &GsaConfig,
) -> Result<(PathBuf, &'static str), String> {
    let resolved = resolve(
        &[
            ("--state-dir", nonempty(cli).map(PathBuf::from)),
            ("GSA_STATE_DIR", nonempty(env).map(PathBuf::from)),
            ("gsa.conf state_dir", cfg.state_dir.clone()),
        ],
        || Ok((PathBuf::from(DEFAULT_STATE_DIR), "the built-in default")),
    )?;
    Ok((resolved.value, resolved.source))
}

/// The canonical recipe store root (2026-10-17 relocation): the build
/// user's working copy of the recipe repository — `GSA_RECIPES_DIR` env >
/// config `recipe_dir` > the build user's `~/.local/share/gsa/recipes`.
/// It is deliberately NOT below the state root: build-domain tools run as
/// the build user and must be able to write where the store lives, and
/// `--state-dir`/`GSA_STATE_DIR` must not drag the store around (the state
/// root keeps index/, abi/, world+sets/, runs/, logs/, locks/,
/// toolchains/, abi-repair/ only).
pub fn recipe_root(cfg: &GsaConfig) -> Result<PathBuf, String> {
    let resolved = resolve(
        &recipe_tiers(std::env::var("GSA_RECIPES_DIR").ok().as_deref(), cfg),
        // The home is only needed for the built-in default, so an explicit
        // override never fails on an unresolvable identity home.
        || {
            Ok((
                default_recipe_root(&build_user_home()?),
                "the built-in default",
            ))
        },
    )?;
    Ok(resolved.value)
}

/// The pure precedence seam for [`recipe_root`] (testable without touching
/// process env); `home` substitutes for the identity-home resolution.
pub fn recipe_root_from(
    env: Option<&str>,
    cfg: &GsaConfig,
    home: &Path,
) -> Result<(PathBuf, &'static str), String> {
    let resolved = resolve(&recipe_tiers(env, cfg), || {
        Ok((default_recipe_root(home), "the built-in default"))
    })?;
    Ok((resolved.value, resolved.source))
}

fn recipe_tiers(env: Option<&str>, cfg: &GsaConfig) -> [(&'static str, Option<PathBuf>); 2] {
    [
        ("GSA_RECIPES_DIR", nonempty(env).map(PathBuf::from)),
        ("gsa.conf recipe_dir", cfg.recipe_dir.clone()),
    ]
}

fn default_recipe_root(home: &Path) -> PathBuf {
    home.join(".local")
        .join("share")
        .join("gsa")
        .join("recipes")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn home() -> PathBuf {
        PathBuf::from("/home/u")
    }

    #[test]
    fn makepkg_conf_assign_reads_quoted_path_values() {
        assert_eq!(
            makepkg_conf_assign("# comment\nSRCDEST = \"/x/y\"\n", "SRCDEST"),
            Some("/x/y".to_string())
        );
        assert_eq!(makepkg_conf_assign("SRCDEST=\n", "SRCDEST"), None);
        assert_eq!(makepkg_conf_assign("PKGDEST=/z\n", "SRCDEST"), None);
    }

    #[test]
    fn makepkg_conf_assign_follows_shell_last_assignment_wins() {
        assert_eq!(
            makepkg_conf_assign("SRCDEST=/first\nSRCDEST=/second\n", "SRCDEST"),
            Some("/second".to_string())
        );
    }

    #[test]
    fn expand_home_path_grows_the_two_home_relative_shapes() {
        let home = PathBuf::from("/home/u");
        assert_eq!(expand_home_path("~", Some(&home)), home);
        assert_eq!(expand_home_path("~/src", Some(&home)), home.join("src"));
        assert_eq!(
            expand_home_path("$HOME/src", Some(&home)),
            home.join("src")
        );
        assert_eq!(
            expand_home_path("${HOME}/src", Some(&home)),
            home.join("src")
        );
        assert_eq!(expand_home_path("/abs/src", Some(&home)), PathBuf::from("/abs/src"));
        // No home known: every shape stays literal rather than guessing.
        assert_eq!(expand_home_path("~/src", None), PathBuf::from("~/src"));
    }

    #[test]
    fn checkout_roots_probe_live_homes_first_and_the_mirror_last() {
        let layout = BuildLayout {
            root: PathBuf::from("/cache"),
            builddir: PathBuf::from("/cache/build"),
            pkgdir: PathBuf::from("/cache/pkg"),
            pkgdest: PathBuf::from("/cache/pkgs"),
        };
        let recipe = PathBuf::from("/ws/packages/misc/demo");
        let srcdest = PathBuf::from("/home/u/.cache/gsa-src");
        assert_eq!(
            checkout_roots_in(&recipe, Some("demo"), &layout, Some(&srcdest)),
            vec![
                PathBuf::from("/cache/build/demo/src"),
                recipe.join("src"),
                recipe.clone(),
                srcdest,
            ]
        );
        // Revision probing passes no mirror tier at all.
        assert_eq!(
            checkout_roots_in(&recipe, Some("demo"), &layout, None),
            vec![
                PathBuf::from("/cache/build/demo/src"),
                recipe.join("src"),
                recipe.clone(),
            ]
        );
    }

    #[test]
    fn checkout_roots_without_pkgbase_scan_the_cache_trees_in_stable_order() {
        let tmp = std::env::temp_dir().join(format!("gsa-roots-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(tmp.join("build/bbb/src")).unwrap();
        std::fs::create_dir_all(tmp.join("build/aaa/src")).unwrap();
        let layout = BuildLayout {
            root: tmp.clone(),
            builddir: tmp.join("build"),
            pkgdir: tmp.join("pkg"),
            pkgdest: tmp.join("pkgs"),
        };
        let recipe = PathBuf::from("/ws/packages/misc/demo");
        let roots = checkout_roots_in(&recipe, None, &layout, None);
        assert_eq!(
            roots,
            vec![
                tmp.join("build/aaa/src"),
                tmp.join("build/bbb/src"),
                recipe.join("src"),
                recipe.clone(),
            ]
        );
        std::fs::remove_dir_all(&tmp).unwrap();
    }

    #[test]
    fn a_layer_parses_keys_comments_and_tilde() {
        let cfg = parse_layer(
            "# comment\n\nproject = ~/Projects/gsa\nrecipe_url = https://example.invalid/r.git\n\
             build_dir = /var/tmp/bd\nstate_dir = ~\nrecipe_dir = ~/store\n",
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
        assert_eq!(cfg.recipe_dir, Some(PathBuf::from("/home/u/store")));
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
            (PathBuf::from("--flag"), "--state-dir")
        );
        assert_eq!(
            resolve_state_dir_from(None, Some("/env"), &cfg).unwrap(),
            (PathBuf::from("/env"), "GSA_STATE_DIR")
        );
        assert_eq!(
            resolve_state_dir_from(None, None, &cfg).unwrap(),
            (PathBuf::from("/cfg"), "gsa.conf state_dir")
        );
        assert_eq!(
            resolve_state_dir_from(None, Some("  "), &GsaConfig::default()).unwrap(),
            (PathBuf::from(DEFAULT_STATE_DIR), "the built-in default")
        );
        // A blank flag is unset too, and a blank env never masks the config.
        assert_eq!(
            resolve_state_dir_from(Some(" "), Some("  "), &cfg).unwrap(),
            (PathBuf::from("/cfg"), "gsa.conf state_dir")
        );
    }

    #[test]
    fn recipe_root_precedence_is_env_then_config_then_the_build_user_data_home() {
        let cfg = GsaConfig {
            recipe_dir: Some(PathBuf::from("/cfg/recipes")),
            ..GsaConfig::default()
        };
        assert_eq!(
            recipe_root_from(Some("/env/recipes"), &cfg, &home()).unwrap(),
            (PathBuf::from("/env/recipes"), "GSA_RECIPES_DIR")
        );
        assert_eq!(
            recipe_root_from(None, &cfg, &home()).unwrap(),
            (PathBuf::from("/cfg/recipes"), "gsa.conf recipe_dir")
        );
        // A blank env value is unset (the build_root convention), and the
        // default is the build user's XDG data home — never the state root.
        assert_eq!(
            recipe_root_from(Some("  "), &GsaConfig::default(), &home()).unwrap(),
            (
                home()
                    .join(".local")
                    .join("share")
                    .join("gsa")
                    .join("recipes"),
                "the built-in default"
            )
        );
    }

    #[test]
    fn srcdest_precedence_is_env_then_the_user_conf_then_the_system_conf() {
        let home = home();
        let user = "SRCDEST=~/u-src\n";
        let system = "SRCDEST=/etc-src\n";
        assert_eq!(
            resolve_srcdest_from(Some("/env-src"), Some(user), Some(system), Some(&home)),
            Resolved {
                value: Some(PathBuf::from("/env-src")),
                source: "SRCDEST",
            }
        );
        assert_eq!(
            resolve_srcdest_from(None, Some(user), Some(system), Some(&home)),
            Resolved {
                value: Some(home.join("u-src")),
                source: "~/.makepkg.conf SRCDEST",
            }
        );
        assert_eq!(
            resolve_srcdest_from(None, None, Some(system), Some(&home)),
            Resolved {
                value: Some(PathBuf::from("/etc-src")),
                source: "/etc/makepkg.conf SRCDEST",
            }
        );
        // No tier supplied one: `None` survives, with the label the callers'
        // `None` branch would otherwise have to invent.
        assert_eq!(
            resolve_srcdest_from(None, None, None, Some(&home)),
            Resolved {
                value: None,
                source: "no SRCDEST",
            }
        );
        // An empty env value is unset (SRCDEST's own convention: trim does
        // not enter into it), so the next rung answers.
        assert_eq!(
            resolve_srcdest_from(Some(""), Some(user), None, Some(&home)),
            Resolved {
                value: Some(home.join("u-src")),
                source: "~/.makepkg.conf SRCDEST",
            }
        );
        // A conf file without the key contributes nothing.
        assert_eq!(
            resolve_srcdest_from(None, Some("PKGDEST=/pkgs\n"), None, Some(&home)),
            Resolved {
                value: None,
                source: "no SRCDEST",
            }
        );
    }

    #[test]
    fn the_one_ladder_takes_the_first_supplied_rung_and_its_label() {
        let tiers = [
            ("top", None),
            ("middle", Some("/mid")),
            ("bottom", Some("/low")),
        ];
        assert_eq!(
            resolve(&tiers, || Ok(("/default", "the built-in default"))).unwrap(),
            Resolved {
                value: "/mid",
                source: "middle",
            }
        );
        // No rung supplied a value: the default rung answers with its own
        // label, and only then is the closure evaluated.
        let none: [(&'static str, Option<&str>); 2] = [("top", None), ("bottom", None)];
        assert_eq!(
            resolve(&none, || Ok(("/default", "the built-in default"))).unwrap(),
            Resolved {
                value: "/default",
                source: "the built-in default",
            }
        );
    }

    #[test]
    fn recipe_dir_merges_per_key_like_every_other_key() {
        let system = parse_layer("recipe_dir = /sys/store\nstate_dir = /sys\n", "s", &home())
            .unwrap();
        let user = parse_layer("recipe_dir = /usr/store\n", "u", &home()).unwrap();
        let merged = system.merged_with(user);
        assert_eq!(merged.recipe_dir, Some(PathBuf::from("/usr/store")));
        assert_eq!(merged.state_dir, Some(PathBuf::from("/sys")));
    }

    #[test]
    fn the_workspace_hint_teaches_the_store_era_remedy() {
        assert!(WORKSPACE_HINT.contains("set `project` in gsa.conf"), "{WORKSPACE_HINT}");
        assert!(WORKSPACE_HINT.contains("sudo gsa -Sy"), "{WORKSPACE_HINT}");
    }
}
