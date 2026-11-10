//! The `gsa.conf` config surface (docs/plans/plan-gsa-isolation.md W2, locked decision
//! 5; contract §B.11/§J.4). Two directories, auto-read, no CLI flag:
//!
//!   `/etc/gsa/gsa.conf`                system layer (root)
//!   `~/.config/gsa/gsa.conf`           user layer (the build user's home:
//!                                      SUDO_UID's passwd home under a sudo
//!                                      run, else `$HOME`)
//!
//! The same two directories also hold the per-compiler makepkg bodies
//! (`gcc-makepkg.conf`, `clang-makepkg.conf` — see [`crate::makepkg_conf`]),
//! which is why the layer unit is a DIRECTORY: one resolution answers "where
//! does this site keep its engine configuration" for every file, instead of a
//! second ladder per file name.
//!
//! Per key the USER layer wins over the system layer, which wins over the
//! built-ins (locked decision 5). The keys are `project`, `recipe_url`,
//! `build_dir`, `state_dir`, `recipe_dir`, `srcdest`; an unknown key is an ERROR naming
//! file:line — a typo'd key must never silently mean "built-in default". The plan's fifth
//! key group ("defaults") is deliberately not implemented: the project's
//! `build-defaults.conf` already owns per-project defaults and a second
//! surface for the same knobs is a trap (2026-10-16, noted in JOURNAL).
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

/// The system configuration directory (baseline layer): root-owned, shipped
/// by the `gsa-pm` recipe.
pub const SYSTEM_CONF_DIR: &str = "/etc/gsa";

/// The user configuration directory below the build user's home — the clone
/// that overrides the baseline file by file.
pub const USER_CONF_DIR: &str = ".config/gsa";

/// The engine's own config file name inside a configuration directory (strict
/// `key = value`; NOT a shell body, never sourced by makepkg).
pub const GSA_CONF_NAME: &str = "gsa.conf";

/// The retired single-file system layer. Still read (with one warning) when
/// the new directory holds no `gsa.conf`, so an upgraded engine never loses an
/// operator's `build_dir` mid-transition; contract §B.9 carries the row.
pub const LEGACY_SYSTEM_CONFIG: &str = "/etc/gsa.conf";

/// The built-in recipe-store upstream (the recipe repository's origin).
pub const DEFAULT_RECIPE_URL: &str = "https://github.com/ZhangDM-520/gsa-recipe.git";

/// The shared "no recipe workspace found" remedy. One string, one home:
/// every user-visible not-found path renders this same clause (the CLI's
/// discovery errors and the topology loader's not-found error alike) — the
/// retired cwd-only advice taught a workflow the store replaced.
pub const WORKSPACE_HINT: &str =
    "set `project` in gsa.conf, run inside the recipe repository, or fetch the store with `sudo gsa -Sy`";

/// The build-cache layout (docs/plans/plan-gsa-isolation.md W4): the build user's
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
const KEYS: [&str; 6] = [
    "project",
    "recipe_url",
    "build_dir",
    "state_dir",
    "recipe_dir",
    "srcdest",
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
    /// The makepkg source cache (contract §B.11): the engine owns it now, so a
    /// build domain that was retired from makepkg.conf still has one ladder.
    pub srcdest: Option<PathBuf>,
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
            srcdest: over.srcdest.or(self.srcdest),
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
            "srcdest" => cfg.srcdest = Some(expand_home(value, home)),
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

/// The makepkg `SRCDEST` of the build domain (contract §B.11): the engine's
/// OWN `gsa.conf` ladder — the `srcdest` key (user layer already merged over
/// the baseline) beats the built-in `~/.gsa-src`.
///
/// The `SRCDEST` environment rung and both makepkg.conf rungs are GONE: the
/// engine stopped honouring makepkg.conf, and a second ladder for one path is
/// how the 2026-10-16 "checkout invisible, anchor deferred
/// source-unfetchable" smoke happened. An unreadable config contributes
/// nothing here — every command loads the config through its own path first,
/// so the loud failure belongs to that call, not to a silently different
/// source mirror.
pub fn resolve_srcdest() -> Option<PathBuf> {
    resolve_srcdest_with_source().0
}

/// [`resolve_srcdest`] plus the rung that decided it; `"no SRCDEST"` only
/// when no rung could answer (no `srcdest` key AND no resolvable build-user
/// home for the built-in).
pub fn resolve_srcdest_with_source() -> (Option<PathBuf>, &'static str) {
    let cfg = load().unwrap_or_default();
    let home = build_user_home().ok();
    let (value, source) = resolve_srcdest_from(&cfg, home.as_deref());
    (value, source)
}

/// The pure precedence seam for [`resolve_srcdest`] (testable without the
/// process environment or the filesystem).
fn resolve_srcdest_from(
    cfg: &GsaConfig,
    home: Option<&Path>,
) -> (Option<PathBuf>, &'static str) {
    match resolve_opt(&[("gsa.conf srcdest", cfg.srcdest.clone())]) {
        Some(resolved) => (Some(resolved.value), resolved.source),
        None => match home {
            Some(home) => (Some(home.join(".gsa-src")), "the built-in default"),
            None => (None, "no SRCDEST"),
        },
    }
}

/// Load every auto-read layer, user over system over built-ins. Missing files
/// are fine (the layer simply contributes nothing); malformed files fail loud.
/// `GSA_CONF` (fixture/hermetic control, like `GSA_STATE_DIR`) replaces the
/// `gsa.conf` layers with exactly one file; `GSA_CONF_DIR` replaces the whole
/// directory resolution with one directory, which is what a fixture needs so
/// the host's `/etc/gsa` can never leak into the battery.
pub fn load() -> Result<GsaConfig, String> {
    if let Ok(path) = std::env::var("GSA_CONF") {
        if !path.is_empty() {
            let home = build_user_home()?;
            return read_layer(Path::new(&path), &home);
        }
    }
    let home = build_user_home()?;
    let layers = conf_layers_with(std::env::var("GSA_CONF_DIR").ok().as_deref(), &home);
    let mut cfg = GsaConfig::default();
    // The retired single-file layer is the LOWEST rung, so a site that has
    // already migrated wins outright; reading it keeps the transition silent
    // in behaviour and loud only in the warning.
    if layers.auto {
        if let Some(legacy) = legacy_layer(&home)? {
            cfg = cfg.merged_with(legacy);
        }
    }
    for dir in &layers.dirs {
        cfg = cfg.merged_with(read_layer(&dir.join(GSA_CONF_NAME), &home)?);
    }
    Ok(cfg)
}

/// One configuration-directory resolution: `dirs` are in SOURCE order (the
/// baseline first, the override last), so merging walks them forwards.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfLayers {
    pub dirs: Vec<PathBuf>,
    /// Whether this is the auto-read resolution (the only one that consults
    /// the retired `/etc/gsa.conf`).
    pub auto: bool,
    pub source: &'static str,
}

impl ConfLayers {
    /// The directory a per-compiler body is looked up in, highest precedence
    /// first.
    pub fn lookup(&self) -> impl Iterator<Item = &Path> {
        self.dirs.iter().rev().map(PathBuf::as_path)
    }
}

/// The live directory resolution. `GSA_CONF_DIR` wins outright (one
/// directory, both rungs collapse onto it) — the fixture and hermetic control,
/// the same shape `GSA_CONF` has for the file.
pub fn conf_layers() -> Result<ConfLayers, String> {
    let home = build_user_home()?;
    Ok(conf_layers_with(
        std::env::var("GSA_CONF_DIR").ok().as_deref(),
        &home,
    ))
}

/// The pure half of [`conf_layers`] (testable without process env).
pub fn conf_layers_with(env: Option<&str>, home: &Path) -> ConfLayers {
    if let Some(dir) = nonempty(env) {
        return ConfLayers {
            dirs: vec![PathBuf::from(dir)],
            auto: false,
            source: "GSA_CONF_DIR",
        };
    }
    ConfLayers {
        dirs: vec![
            PathBuf::from(SYSTEM_CONF_DIR),
            home.join(USER_CONF_DIR),
        ],
        auto: true,
        source: "the built-in directories",
    }
}

/// The generated makepkg composite's source list for one toolchain: the
/// universal body, then every configuration directory's per-compiler body in
/// source order. Returns the paths only — the caller renders the shell, so
/// this module stays the one place that knows the layout.
pub fn makepkg_conf_sources(toolchain: crate::toolchain::Toolchain) -> Result<(ConfLayers, Vec<PathBuf>), String> {
    let layers = conf_layers()?;
    let name = toolchain.conf_name();
    let paths = layers
        .dirs
        .iter()
        .map(|dir| dir.join(name))
        .filter(|path| path.is_file())
        .collect();
    Ok((layers, paths))
}

/// The retired `/etc/gsa.conf`, when it still exists. Warns exactly once per
/// process: it is read as the baseline while `/etc/gsa/gsa.conf` is absent
/// (the operator's `build_dir` keeps working), and ignored — loudly — once
/// the new file exists, so two live homes can never drift apart.
fn legacy_layer(home: &Path) -> Result<Option<GsaConfig>, String> {
    let legacy = Path::new(LEGACY_SYSTEM_CONFIG);
    if !legacy.is_file() {
        return Ok(None);
    }
    let migrated = Path::new(SYSTEM_CONF_DIR).join(GSA_CONF_NAME).is_file();
    if migrated {
        warn_once(&format!(
            "gsa: {LEGACY_SYSTEM_CONFIG} is retired and IGNORED ({SYSTEM_CONF_DIR}/{GSA_CONF_NAME} exists) — delete the old file"
        ));
        return Ok(None);
    }
    warn_once(&format!(
        "gsa: {LEGACY_SYSTEM_CONFIG} is retired — move it to {SYSTEM_CONF_DIR}/{GSA_CONF_NAME}"
    ));
    read_layer(legacy, home).map(Some)
}

/// One warning per process: `load()` runs on every command that needs the
/// config, and a migration notice repeated per invocation is noise, not a
/// reminder.
fn warn_once(message: &str) {
    use std::sync::Once;
    static ONCE: Once = Once::new();
    ONCE.call_once(|| eprintln!("{message}"));
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

/// The operator's recipe-repository checkout (`GSA_RECIPE_CHECKOUT`, contract
/// §B.8): the recipe half of the project is its own repository, so anything
/// that needs the real `config/` + `packages/` tree — the fixture battery's
/// real-tree sections and the `recipe-tree` integration test — reads its
/// location from this input instead of assuming a path inside the engine
/// checkout.
///
/// Deliberately not a rung on a ladder (rule 73): it has no config key and no
/// built-in rung, because `None` is a real answer — an engine-only checkout has
/// no recipe tree, and the caller skips loudly. One environment read.
pub fn recipe_checkout() -> Option<PathBuf> {
    let value = std::env::var("GSA_RECIPE_CHECKOUT").ok()?;
    recipe_checkout_from(&value, build_user_home().ok().as_deref())
}

/// The pure half of [`recipe_checkout`]: a blank/whitespace value is unset
/// (the `GSA_*` path-input convention) and `~`/`~/…` expands against the build
/// user's home.
fn recipe_checkout_from(value: &str, home: Option<&Path>) -> Option<PathBuf> {
    let value = nonempty(Some(value))?;
    Some(match home {
        Some(home) => expand_home(value, home),
        None => PathBuf::from(value),
    })
}

/// Create `dir` for the build user, one level at a time: every missing
/// ancestor the engine brings into existence is handed to the build user as
/// it is created. A `create_dir_all` as root would leave the whole new chain
/// root-owned and unremovable by the build user (rule 19; 2026-10-17 sweep:
/// the battery's fresh per-fixture caches ended up `rm`-proof one level above
/// the cache root).
///
/// One seam for every writer of the build-cache root (`gsa-build`'s lane
/// command and `gsa-fetch`'s config install): the fetch path materializes the
/// root before the first lane exists, so a second copy of this walk would be
/// the one that forgot the ownership handoff.
pub fn create_owned_dir(dir: &Path) -> Result<(), String> {
    let mut missing: Vec<&Path> = Vec::new();
    let mut cursor = dir;
    while !cursor.exists() {
        missing.push(cursor);
        cursor = cursor
            .parent()
            .ok_or_else(|| format!("cannot resolve the parent of {}", dir.display()))?;
    }
    for path in missing.into_iter().rev() {
        // Concurrent lanes resolve the same layout: another one may create a
        // level between our exists() walk and here — EEXIST is success.
        match std::fs::create_dir(path) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(format!("cannot create {}: {error}", path.display())),
        }
        crate::privilege::own_to_build_user(path)
            .map_err(|error| format!("cannot hand {} to the build user: {error}", path.display()))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn home() -> PathBuf {
        PathBuf::from("/home/u")
    }

    #[test]
    fn conf_layers_put_the_baseline_first_and_the_user_clone_last() {
        let home = home();
        let layers = conf_layers_with(None, &home);
        assert_eq!(
            layers.dirs,
            vec![PathBuf::from("/etc/gsa"), home.join(".config/gsa")]
        );
        assert!(layers.auto, "the auto resolution consults the legacy file");
        assert_eq!(layers.source, "the built-in directories");
        // Lookup order is the reverse of source order: the user clone is
        // consulted first, and the baseline is the fallback.
        assert_eq!(
            layers.lookup().collect::<Vec<_>>(),
            vec![home.join(".config/gsa").as_path(), Path::new("/etc/gsa")]
        );
    }

    #[test]
    fn gsa_conf_dir_collapses_the_resolution_and_skips_the_legacy_file() {
        // One directory, exactly like `GSA_CONF` for the file: a fixture must
        // never see the host's /etc/gsa, nor be warned about /etc/gsa.conf.
        let layers = conf_layers_with(Some("/tmp/hermetic"), &home());
        assert_eq!(layers.dirs, vec![PathBuf::from("/tmp/hermetic")]);
        assert!(!layers.auto);
        assert_eq!(layers.source, "GSA_CONF_DIR");
        // A blank value is unset, like every `GSA_*` path input.
        assert!(conf_layers_with(Some("   "), &home()).auto);
    }

    #[test]
    fn srcdest_is_gsa_conf_or_the_built_in() {
        let home = home();
        // The key decides when set — the env is no longer consulted at all.
        let mut cfg = GsaConfig {
            srcdest: Some(PathBuf::from("/mirror")),
            ..GsaConfig::default()
        };
        assert_eq!(
            resolve_srcdest_from(&cfg, Some(&home)),
            (Some(PathBuf::from("/mirror")), "gsa.conf srcdest")
        );
        // Unset falls to the built-in, which keeps the existing multi-GB
        // source cache in place (~/.gsa-src) rather than orphaning it.
        cfg.srcdest = None;
        assert_eq!(
            resolve_srcdest_from(&cfg, Some(&home)),
            (Some(home.join(".gsa-src")), "the built-in default")
        );
        // No home to expand against: the caller's `None` branch gets a label.
        assert_eq!(resolve_srcdest_from(&cfg, None), (None, "no SRCDEST"));
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
    fn srcdest_has_exactly_one_ladder() {
        // Regression for the retired two-ladder shape: a `SRCDEST` in the
        // environment must NOT beat the config key any more (the engine owns
        // the source cache; contract §B.11).
        let home = home();
        let cfg = GsaConfig {
            srcdest: Some(PathBuf::from("/cfg-src")),
            ..GsaConfig::default()
        };
        assert_eq!(
            resolve_srcdest_from(&cfg, Some(&home)).0,
            Some(PathBuf::from("/cfg-src")),
            "the env rung is gone; only gsa.conf decides"
        );
    }

    #[test]
    fn recipe_checkout_is_one_env_read_blank_unset_and_tilde_expanded() {
        // A blank/whitespace value is unset, like every `GSA_*` path input.
        assert_eq!(recipe_checkout_from("", Some(&home())), None);
        assert_eq!(recipe_checkout_from("   ", Some(&home())), None);
        // `~`/`~/…` grows against the build user's home; everything else is
        // taken literally (this input has no other relative shape).
        assert_eq!(recipe_checkout_from("~", Some(&home())), Some(home()));
        assert_eq!(
            recipe_checkout_from("~/src/gsa-recipe", Some(&home())),
            Some(home().join("src/gsa-recipe"))
        );
        assert_eq!(
            recipe_checkout_from("/srv/gsa-recipe", Some(&home())),
            Some(PathBuf::from("/srv/gsa-recipe"))
        );
        // No resolvable home: `~` stays literal rather than failing the read.
        assert_eq!(
            recipe_checkout_from("~/src", None),
            Some(PathBuf::from("~/src"))
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
