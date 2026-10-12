//! Recipe metadata: the narrowed read path of contract §A.2.3.
//!
//! PKGBUILD stays the recipe of record and the build payload (`makepkg`
//! executes it), but this engine NEVER evaluates recipe shell. Metadata is
//! read from the committed `.SRCINFO`; facts `.SRCINFO` does not carry fall
//! back to a strict read-only scan of the `PKGBUILD` (top-level literal
//! assignments and function names only). "Strict" means the scan never
//! guesses: a value built by shell expansion is marked *dynamic*, and a fact
//! that cannot be answered from either source is a usage-level error naming
//! the recipe and the missing fact — never a shell evaluation.
//!
//! All parsers are infallible-with-respect-to-panics: arbitrary bytes yield
//! structured errors or `dynamic` facts.

use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::rc::Rc;

use gsa_model::{RecipeId, TopologyRecord};

pub mod elf;
pub mod pkginfo;

/// A recipe-metadata refusal: names the recipe/file and, when the offender
/// lives on one, its line.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RecipeError {
    pub origin: String,
    pub line: Option<usize>,
    pub message: String,
}

impl RecipeError {
    fn at(origin: &str, line: usize, message: impl Into<String>) -> Self {
        RecipeError {
            origin: origin.to_string(),
            line: Some(line),
            message: message.into(),
        }
    }

    fn whole(origin: &str, message: impl Into<String>) -> Self {
        RecipeError {
            origin: origin.to_string(),
            line: None,
            message: message.into(),
        }
    }

    /// The contract's usage-level error (§A.2.3): the recipe's read path
    /// cannot answer this fact from `.SRCINFO` or the scan.
    pub fn missing_fact(origin: &str, fact: &str) -> Self {
        RecipeError::whole(
            origin,
            format!(
                "missing fact '{fact}' (absent from committed .SRCINFO and not scannable without evaluating the recipe)"
            ),
        )
    }
}

impl std::fmt::Display for RecipeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self.line {
            Some(n) => write!(f, "{}:{}: {}", self.origin, n, self.message),
            None => write!(f, "{}: {}", self.origin, self.message),
        }
    }
}

impl std::error::Error for RecipeError {}

// ---------------------------------------------------------------------------
// .SRCINFO
// ---------------------------------------------------------------------------

/// Committed `.SRCINFO` metadata. Multi-value keys accumulate in order;
/// single-value keys keep their first occurrence. Keys outside the known set
/// are kept in `other` so a new makepkg key never becomes a parse failure.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Srcinfo {
    pub pkgbase: Option<String>,
    pub pkgnames: Vec<String>,
    pub pkgdesc: Option<String>,
    pub pkgver: Option<String>,
    pub pkgrel: Option<String>,
    pub epoch: Option<String>,
    pub url: Option<String>,
    pub arch: Vec<String>,
    pub license: Vec<String>,
    pub groups: Vec<String>,
    pub depends: Vec<String>,
    pub makedepends: Vec<String>,
    pub checkdepends: Vec<String>,
    pub optdepends: Vec<String>,
    pub provides: Vec<String>,
    pub conflicts: Vec<String>,
    pub replaces: Vec<String>,
    pub source: Vec<String>,
    pub validpgpkeys: Vec<String>,
    pub other: BTreeMap<String, Vec<String>>,
}

impl Srcinfo {
    fn set_single(&mut self, key: &str, value: String) {
        let slot = match key {
            "pkgbase" => &mut self.pkgbase,
            "pkgdesc" => &mut self.pkgdesc,
            "pkgver" => &mut self.pkgver,
            "pkgrel" => &mut self.pkgrel,
            "epoch" => &mut self.epoch,
            "url" => &mut self.url,
            _ => {
                self.other.entry(key.to_string()).or_default().push(value);
                return;
            }
        };
        if slot.is_none() {
            *slot = Some(value);
        }
    }

    fn push_multi(&mut self, key: &str, value: String) {
        let slot = match key {
            "pkgname" => &mut self.pkgnames,
            "arch" => &mut self.arch,
            "license" => &mut self.license,
            "groups" => &mut self.groups,
            "depends" => &mut self.depends,
            "makedepends" => &mut self.makedepends,
            "checkdepends" => &mut self.checkdepends,
            "optdepends" => &mut self.optdepends,
            "provides" => &mut self.provides,
            "conflicts" => &mut self.conflicts,
            "replaces" => &mut self.replaces,
            "source" => &mut self.source,
            "validpgpkeys" => &mut self.validpgpkeys,
            _ => {
                self.other.entry(key.to_string()).or_default().push(value);
                return;
            }
        };
        slot.push(value);
    }

    /// `[epoch:]pkgver-pkgrel`, the pacman full version.
    pub fn full_version(&self) -> Option<String> {
        let pkgver = self.pkgver.as_deref()?;
        let pkgrel = self.pkgrel.as_deref()?;
        let epoch = self.epoch.as_deref().unwrap_or("");
        if epoch.is_empty() {
            Some(format!("{pkgver}-{pkgrel}"))
        } else {
            Some(format!("{epoch}:{pkgver}-{pkgrel}"))
        }
    }
}

fn key_is_wellformed(key: &str) -> bool {
    !key.is_empty()
        && key
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, '_' | '-'))
}

/// Parse committed `.SRCINFO` content. Grammar: optional indentation,
/// `key = value`; one row per value. A line that is not `key = value` is a
/// parse error naming the line (a silently dropped key is exactly the drift
/// class the committed file exists to prevent).
pub fn parse_srcinfo(content: &str, origin: &str) -> Result<Srcinfo, RecipeError> {
    let mut info = Srcinfo::default();
    for (idx, raw_line) in content.lines().enumerate() {
        let line_no = idx + 1;
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            return Err(RecipeError::at(
                origin,
                line_no,
                format!("malformed .SRCINFO line (expected 'key = value'): {line}"),
            ));
        };
        let key = key.trim();
        let value = value.trim();
        if !key_is_wellformed(key) {
            return Err(RecipeError::at(
                origin,
                line_no,
                format!("malformed .SRCINFO key '{key}' (expected [a-z0-9_-]+): {line}"),
            ));
        }
        if key == "pkgname" {
            info.push_multi(key, value.to_string());
        } else if matches!(
            key,
            "arch"
                | "license"
                | "groups"
                | "depends"
                | "makedepends"
                | "checkdepends"
                | "optdepends"
                | "provides"
                | "conflicts"
                | "replaces"
                | "source"
                | "validpgpkeys"
        ) {
            info.push_multi(key, value.to_string());
        } else {
            info.set_single(key, value.to_string());
        }
    }
    Ok(info)
}

/// Byte-oriented entry point: `.SRCINFO` is read lossily, so arbitrary bytes
/// parse (or fail) without ever panicking.
pub fn parse_srcinfo_bytes(bytes: &[u8], origin: &str) -> Result<Srcinfo, RecipeError> {
    parse_srcinfo(&String::from_utf8_lossy(bytes), origin)
}

// ---------------------------------------------------------------------------
// Section-tagged .SRCINFO rows (QA lints, fish `srcinfo_rows`)
// ---------------------------------------------------------------------------

/// Section-tagged committed-`.SRCINFO` rows. The QA lints (`gsa-qa`) need to
/// know WHICH section a `provides`/`conflicts`/dependency row belongs to:
/// the pkgbase section (handle `''` — makepkg merges it into every output) or
/// one output's own `pkgname` section (handle = that output name). A sibling
/// output's section never counts for an output (the swap rule's counterpart
/// test), which the flattened [`Srcinfo`] cannot express. Grammar and
/// strictness are byte-identical to [`parse_srcinfo`]: one `key = value` per
/// row, keys `[a-z0-9_-]+`, and a non-conforming line is an error naming the
/// line — never a silent drop.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SrcinfoRows {
    pub pkgbase: Option<String>,
    pub pkgnames: Vec<String>,
    /// `(handle, value)` pairs; handle `''` is the pkgbase section.
    pub provides: Vec<(String, String)>,
    /// `(handle, value)` pairs; handle `''` is the pkgbase section. Empty
    /// values are KEPT (a split output's unset array slot ships as
    /// `provides = `, metadata that names nothing — the swap lint flags it).
    pub conflicts: Vec<(String, String)>,
    /// `(field, handle, value)` for `depends|makedepends|optdepends|checkdepends`.
    pub deps: Vec<(String, String, String)>,
}

impl SrcinfoRows {
    /// The declared name set of the recipe (fish `B`/`N` rows): pkgbase plus
    /// every pkgname, deduped in declaration order.
    pub fn names(&self) -> Vec<String> {
        let mut names = Vec::new();
        if let Some(base) = &self.pkgbase {
            names.push(base.clone());
        }
        for name in &self.pkgnames {
            if !names.contains(name) {
                names.push(name.clone());
            }
        }
        names
    }

    /// The output names (fish `N` rows), falling back to the pkgbase when a
    /// record carries no `pkgname` row at all.
    pub fn outputs(&self) -> Vec<String> {
        if self.pkgnames.is_empty() {
            self.pkgbase.clone().into_iter().collect()
        } else {
            self.pkgnames.clone()
        }
    }
}

/// Parse committed `.SRCINFO` into section-tagged rows ([`SrcinfoRows`]).
/// Section tracking is the file's own: rows before the first `pkgname` row
/// belong to the pkgbase section (handle `''`); a `pkgname = <out>` row
/// switches the current section to that output.
pub fn parse_srcinfo_rows(content: &str, origin: &str) -> Result<SrcinfoRows, RecipeError> {
    let mut rows = SrcinfoRows::default();
    let mut handle = String::new();
    for (idx, raw_line) in content.lines().enumerate() {
        let line_no = idx + 1;
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            return Err(RecipeError::at(
                origin,
                line_no,
                format!("malformed .SRCINFO line (expected 'key = value'): {line}"),
            ));
        };
        let key = key.trim();
        let value = value.trim();
        if !key_is_wellformed(key) {
            return Err(RecipeError::at(
                origin,
                line_no,
                format!("malformed .SRCINFO key '{key}' (expected [a-z0-9_-]+): {line}"),
            ));
        }
        match key {
            "pkgbase" => {
                if rows.pkgbase.is_none() {
                    rows.pkgbase = Some(value.to_string());
                }
            }
            "pkgname" => {
                rows.pkgnames.push(value.to_string());
                handle = value.to_string();
            }
            "provides" => rows.provides.push((handle.clone(), value.to_string())),
            "conflicts" => rows.conflicts.push((handle.clone(), value.to_string())),
            "depends" | "makedepends" | "optdepends" | "checkdepends" => {
                rows.deps
                    .push((key.to_string(), handle.clone(), value.to_string()))
            }
            _ => {}
        }
    }
    Ok(rows)
}

// ---------------------------------------------------------------------------
// Strict read-only PKGBUILD scan
// ---------------------------------------------------------------------------

/// One scanned top-level fact: a literal value, or `dynamic` when the recipe
/// builds it with shell syntax (never evaluated here).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ScanValue {
    Scalar(String),
    Array(Vec<String>),
}

/// The result of scanning a `PKGBUILD` read-only: top-level literal
/// assignments, the keys whose values are shell-dynamic, and the function
/// names defined (`pkgver()`, `build()`, `package()`, …).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PkgbuildScan {
    pub vars: BTreeMap<String, ScanValue>,
    pub dynamic: BTreeSet<String>,
    pub functions: BTreeSet<String>,
}

fn shell_dynamic(value: &str) -> bool {
    value.contains('$') || value.contains('`')
}

fn strip_quotes(value: &str) -> &str {
    let v = value.trim();
    if v.len() >= 2 {
        let bytes = v.as_bytes();
        if (bytes[0] == b'"' && bytes[v.len() - 1] == b'"')
            || (bytes[0] == b'\'' && bytes[v.len() - 1] == b'\'')
        {
            return &v[1..v.len() - 1];
        }
    }
    v
}

/// Scan `PKGBUILD` content read-only. Never evaluates shell, never panics:
/// anything the scanner cannot pin down becomes a `dynamic` marker or is
/// skipped, and strictness lives in [`RecipeMeta::scan_fact`] which refuses
/// to answer a dynamic/absent fact.
pub fn scan_pkgbuild(content: &str) -> PkgbuildScan {
    let mut scan = PkgbuildScan::default();
    let mut function_depth: i32 = 0;
    let mut pending_array: Option<String> = None;

    for raw_line in content.lines() {
        let line = raw_line.trim_end();
        let trimmed = line.trim_start();

        if let Some(key) = pending_array.take() {
            // Continuation of a multi-line array until its closing paren.
            let end = trimmed.contains(')');
            let body = trimmed.trim_end_matches(')');
            let mut values = Vec::new();
            for word in body.split_whitespace() {
                let word = strip_quotes(word);
                if word.is_empty() {
                    continue;
                }
                if shell_dynamic(word) {
                    scan.dynamic.insert(key.clone());
                } else {
                    values.push(word.to_string());
                }
            }
            scan.vars
                .entry(key.clone())
                .and_modify(|v| {
                    if let ScanValue::Array(items) = v {
                        items.extend(values.iter().cloned());
                    }
                })
                .or_insert(ScanValue::Array(values));
            if !end {
                pending_array = Some(key);
            }
            continue;
        }

        if function_depth > 0 {
            // Skip function bodies; their braces are shell, not structure
            // this scanner needs. Count braces conservatively and bail out
            // of the body when the depth returns to zero.
            function_depth += trimmed.matches('{').count() as i32;
            function_depth -= trimmed.matches('}').count() as i32;
            if function_depth < 0 {
                function_depth = 0;
            }
            continue;
        }

        // Function definitions are recorded by name (`pkgver()` marks a
        // build-time-versioned VCS recipe — a fact .SRCINFO does not carry).
        if let Some((name, rest)) = trimmed.split_once("()") {
            let name = name.trim();
            if !name.is_empty()
                && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
                && rest.trim_start().starts_with('{')
            {
                scan.functions.insert(name.to_string());
                function_depth += rest.matches('{').count() as i32;
                function_depth -= rest.matches('}').count() as i32;
                if function_depth < 0 {
                    function_depth = 0;
                }
                continue;
            }
        }

        // Top-level assignments only (unindented), never inside a body.
        if raw_line.starts_with(' ') || raw_line.starts_with('\t') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let key = key.trim();
        if key.is_empty() || !key.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
            continue;
        }
        let value = value.trim();
        if let Some(rest) = value.strip_prefix('(') {
            let end = rest.contains(')');
            let body = rest.trim_end_matches(')');
            let mut values = Vec::new();
            for word in body.split_whitespace() {
                let word = strip_quotes(word);
                if word.is_empty() {
                    continue;
                }
                if shell_dynamic(word) {
                    scan.dynamic.insert(key.to_string());
                } else {
                    values.push(word.to_string());
                }
            }
            scan.vars.insert(key.to_string(), ScanValue::Array(values));
            if !end {
                pending_array = Some(key.to_string());
            }
        } else {
            let value = strip_quotes(value);
            if shell_dynamic(value) {
                scan.dynamic.insert(key.to_string());
            } else {
                scan.vars
                    .insert(key.to_string(), ScanValue::Scalar(value.to_string()));
            }
        }
    }
    scan
}

// ---------------------------------------------------------------------------
// Source classification
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VcsKind {
    Git,
    Svn,
    Bzr,
    Hg,
}

impl VcsKind {
    pub fn as_str(self) -> &'static str {
        match self {
            VcsKind::Git => "git",
            VcsKind::Svn => "svn",
            VcsKind::Bzr => "bzr",
            VcsKind::Hg => "hg",
        }
    }
}

/// Where a `source=()` entry's bytes come from: a version-controlled tree, a
/// remote archive, or a file committed beside the recipe.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SourceKind {
    Vcs(VcsKind),
    Remote,
    Local,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ClassifiedSource {
    /// The `name::` alias prefix, when the entry uses one.
    pub name: Option<String>,
    pub location: String,
    pub kind: SourceKind,
}

/// Classify one `source=()` entry (`name::location`, VCS `vcs+transport://`,
/// remote `https://…`, or a local file). The `::` split only fires when the
/// prefix looks like an alias (no `/` or `:` in it).
pub fn classify_source(raw: &str) -> ClassifiedSource {
    let (name, location) = match raw.split_once("::") {
        Some((prefix, rest))
            if !prefix.is_empty() && !prefix.contains('/') && !prefix.contains(':') =>
        {
            (Some(prefix.to_string()), rest.to_string())
        }
        _ => (None, raw.to_string()),
    };
    let kind = {
        let loc = location.as_str();
        let (scheme, _) = loc.split_once("://").unwrap_or((loc, ""));
        let (vcs, _plus) = scheme.split_once('+').unwrap_or((scheme, ""));
        match vcs {
            "git" => SourceKind::Vcs(VcsKind::Git),
            "svn" => SourceKind::Vcs(VcsKind::Svn),
            "bzr" => SourceKind::Vcs(VcsKind::Bzr),
            "hg" => SourceKind::Vcs(VcsKind::Hg),
            _ => {
                if loc.contains("://") {
                    SourceKind::Remote
                } else {
                    SourceKind::Local
                }
            }
        }
    };
    ClassifiedSource {
        name,
        location,
        kind,
    }
}

// ---------------------------------------------------------------------------
// Recipe metadata cache
// ---------------------------------------------------------------------------

/// Where a recipe's metadata came from (contract §A.2.3).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MetaSource {
    /// Committed `.SRCINFO`.
    Srcinfo,
    /// Strict read-only `PKGBUILD` scan fallback.
    Scan,
}

impl MetaSource {
    pub fn as_str(self) -> &'static str {
        match self {
            MetaSource::Srcinfo => ".SRCINFO",
            MetaSource::Scan => "PKGBUILD scan",
        }
    }
}

/// One recipe's read model: metadata from `.SRCINFO` when committed, else
/// from the scan fallback.
#[derive(Clone, Debug)]
pub struct RecipeMeta {
    pub id: RecipeId,
    pub path: String,
    pub srcinfo: Option<Srcinfo>,
    pub scanned: Option<PkgbuildScan>,
    pub source: MetaSource,
}

impl RecipeMeta {
    /// Every output name of the recipe (split outputs included).
    pub fn pkgnames(&self) -> Vec<String> {
        if let Some(info) = &self.srcinfo {
            if !info.pkgnames.is_empty() {
                return info.pkgnames.clone();
            }
        }
        if let Some(scan) = &self.scanned {
            if let Some(value) = scan.vars.get("pkgname") {
                return match value {
                    ScanValue::Scalar(v) => vec![v.clone()],
                    ScanValue::Array(items) => items.clone(),
                };
            }
            if let Some(ScanValue::Scalar(base)) = scan.vars.get("pkgbase") {
                return vec![base.clone()];
            }
        }
        vec![self.id.as_str().to_string()]
    }

    pub fn full_version(&self) -> Result<String, RecipeError> {
        if let Some(info) = &self.srcinfo {
            if let Some(version) = info.full_version() {
                return Ok(version);
            }
        }
        // Scan fallback: pkgver/pkgrel/epoch must be literal.
        let fact = |name: &str| -> Result<String, RecipeError> {
            match self.scanned.as_ref().and_then(|s| s.vars.get(name)) {
                Some(ScanValue::Scalar(v)) => Ok(v.clone()),
                _ => Err(RecipeError::missing_fact(self.id.as_str(), name)),
            }
        };
        let pkgver = fact("pkgver")?;
        let pkgrel = fact("pkgrel")?;
        let epoch = fact("epoch").unwrap_or_default();
        if epoch.is_empty() {
            Ok(format!("{pkgver}-{pkgrel}"))
        } else {
            Ok(format!("{epoch}:{pkgver}-{pkgrel}"))
        }
    }

    pub fn pkgdesc(&self) -> Result<Option<&str>, RecipeError> {
        if let Some(info) = &self.srcinfo {
            return Ok(info.pkgdesc.as_deref());
        }
        Ok(
            match self.scanned.as_ref().and_then(|s| s.vars.get("pkgdesc")) {
                Some(ScanValue::Scalar(v)) => Some(v.as_str()),
                Some(ScanValue::Array(_)) | None => None,
            },
        )
    }

    /// Classified `source=()` entries from whichever source is authoritative.
    pub fn sources(&self) -> Vec<ClassifiedSource> {
        let raw: Vec<String> = if let Some(info) = &self.srcinfo {
            info.source.clone()
        } else if let Some(scan) = &self.scanned {
            match scan.vars.get("source") {
                Some(ScanValue::Array(items)) => items.clone(),
                Some(ScanValue::Scalar(v)) => vec![v.clone()],
                None => Vec::new(),
            }
        } else {
            Vec::new()
        };
        raw.iter().map(|s| classify_source(s)).collect()
    }

    /// A fact `.SRCINFO` does not carry, answered from the scan. A dynamic
    /// or absent value is a usage-level refusal naming the missing fact —
    /// the scan never evaluates shell to produce one.
    pub fn scan_fact(&self, fact: &str) -> Result<String, RecipeError> {
        let Some(scan) = &self.scanned else {
            return Err(RecipeError::missing_fact(self.id.as_str(), fact));
        };
        if scan.dynamic.contains(fact) {
            return Err(RecipeError::missing_fact(self.id.as_str(), fact));
        }
        match scan.vars.get(fact) {
            Some(ScanValue::Scalar(v)) => Ok(v.clone()),
            Some(ScanValue::Array(items)) if items.len() == 1 => Ok(items[0].clone()),
            Some(ScanValue::Array(_)) | None => {
                Err(RecipeError::missing_fact(self.id.as_str(), fact))
            }
        }
    }

    /// `pkgver()` presence: the recipe derives its version at build time
    /// (a VCS recipe marker `.SRCINFO` cannot carry).
    pub fn has_pkgver_function(&self) -> bool {
        self.scanned
            .as_ref()
            .map(|s| s.functions.contains("pkgver"))
            .unwrap_or(false)
    }
}

/// The in-memory recipe cache: `.SRCINFO` (or its scan fallback) parsed once
/// per recipe, with a pkgname→recipe index and lazily cached `PKGBUILD`
/// scans for facts `.SRCINFO` does not carry.
pub struct RecipeDb {
    pub root: PathBuf,
    metas: HashMap<String, Rc<RecipeMeta>>,
    pub order: Vec<RecipeId>,
    pkgname_index: BTreeMap<String, Vec<RecipeId>>,
    scans: RefCell<HashMap<RecipeId, Rc<PkgbuildScan>>>,
}

impl RecipeDb {
    /// Parse every recipe of the topology. A recipe without a committed
    /// `.SRCINFO` falls back to the strict scan; a recipe whose read path can
    /// answer nothing at all is refused by name.
    pub fn load(root: &Path, records: &[TopologyRecord]) -> Result<RecipeDb, RecipeError> {
        let mut db = RecipeDb {
            root: root.to_path_buf(),
            metas: HashMap::new(),
            order: Vec::new(),
            pkgname_index: BTreeMap::new(),
            scans: RefCell::new(HashMap::new()),
        };
        for record in records {
            let dir = root.join(&record.path);
            let origin = record.path.clone();
            let srcinfo_path = dir.join(".SRCINFO");
            let (srcinfo, scanned, source) = if srcinfo_path.is_file() {
                let content = std::fs::read_to_string(&srcinfo_path).map_err(|e| {
                    RecipeError::whole(&origin, format!("cannot read committed .SRCINFO: {e}"))
                })?;
                (
                    Some(parse_srcinfo(&content, &origin)?),
                    None,
                    MetaSource::Srcinfo,
                )
            } else {
                let pkgbuild_path = dir.join("PKGBUILD");
                let content = std::fs::read_to_string(&pkgbuild_path).map_err(|e| {
                    RecipeError::whole(
                        &origin,
                        format!("no committed .SRCINFO and PKGBUILD unreadable: {e}"),
                    )
                })?;
                (None, Some(scan_pkgbuild(&content)), MetaSource::Scan)
            };
            let meta = Rc::new(RecipeMeta {
                id: record.id.clone(),
                path: origin,
                srcinfo,
                scanned,
                source,
            });
            for pkgname in meta.pkgnames() {
                db.pkgname_index
                    .entry(pkgname)
                    .or_default()
                    .push(record.id.clone());
            }
            db.metas.insert(record.id.as_str().to_string(), meta);
            db.order.push(record.id.clone());
        }
        Ok(db)
    }

    pub fn get(&self, id: &str) -> Option<Rc<RecipeMeta>> {
        self.metas.get(id).cloned()
    }

    /// Owner recipes of a pacman package name, split outputs included.
    pub fn by_pkgname(&self, name: &str) -> Option<&[RecipeId]> {
        self.pkgname_index.get(name).map(|v| v.as_slice())
    }

    /// Every `(pkgname, recipe)` pair sorted by pkgname (the `-Q` shape).
    pub fn pkgnames_sorted(&self) -> Vec<(String, Rc<RecipeMeta>)> {
        let mut out: Vec<(String, Rc<RecipeMeta>)> = self
            .pkgname_index
            .keys()
            .filter_map(|name| {
                let owners = self.pkgname_index.get(name)?;
                let meta = self.metas.get(owners[0].as_str())?;
                Some((name.clone(), meta.clone()))
            })
            .collect();
        out.sort_by(|a, b| a.0.cmp(&b.0));
        out
    }

    /// The cached `PKGBUILD` scan of one recipe (for facts `.SRCINFO` does
    /// not carry). Loaded on first use; the scan is read-only.
    pub fn scan_for(&self, id: &RecipeId) -> Result<Rc<PkgbuildScan>, RecipeError> {
        if let Some(scan) = self.scans.borrow().get(id) {
            return Ok(scan.clone());
        }
        let meta = self
            .metas
            .get(id.as_str())
            .ok_or_else(|| RecipeError::whole(id.as_str(), "unknown recipe"))?;
        if let Some(scan) = &meta.scanned {
            let scan = Rc::new(scan.clone());
            self.scans.borrow_mut().insert(id.clone(), scan.clone());
            return Ok(scan);
        }
        let content = std::fs::read_to_string(self.root.join(&meta.path).join("PKGBUILD"))
            .map_err(|e| {
                RecipeError::whole(meta.path.as_str(), format!("PKGBUILD unreadable: {e}"))
            })?;
        let scan = Rc::new(scan_pkgbuild(&content));
        self.scans.borrow_mut().insert(id.clone(), scan.clone());
        Ok(scan)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = "\
pkgbase = zen-browser
\tpkgdesc = Firefox-based web browser built from upstream release source snapshot
\tpkgver = 1.22.3b
\tpkgrel = 2
\tepoch = 1
\turl = https://zen-browser.app
\tarch = x86_64
\tlicense = MPL-2.0
\tmakedepends = rust-git
\tmakedepends = cmake-git
\tdepends = glibc-git
\tprovides = zen-browser-pgo
\tsource = git+https://github.com/zen-browser/desktop.git
\tsource = local.patch
\tsha256sums = SKIP
pkgname = zen-browser
";

    #[test]
    fn srcinfo_parses_metadata_and_outputs() {
        let info = parse_srcinfo(SAMPLE, "packages/stable/zen-browser-pgo").unwrap();
        assert_eq!(info.pkgbase.as_deref(), Some("zen-browser"));
        assert_eq!(info.pkgnames, vec!["zen-browser"]);
        assert_eq!(info.pkgver.as_deref(), Some("1.22.3b"));
        assert_eq!(info.full_version().as_deref(), Some("1:1.22.3b-2"));
        assert_eq!(info.makedepends, vec!["rust-git", "cmake-git"]);
        assert_eq!(info.provides, vec!["zen-browser-pgo"]);
        assert_eq!(info.source.len(), 2);
        assert_eq!(
            info.other.get("sha256sums").unwrap(),
            &vec!["SKIP".to_string()]
        );
    }

    #[test]
    fn srcinfo_supports_split_outputs() {
        let info = parse_srcinfo(
            "pkgbase = qt\npkgver = 1\npkgrel = 2\npkgname = qt\npkgname = qt-docs\n",
            "x",
        )
        .unwrap();
        assert_eq!(info.pkgnames, vec!["qt", "qt-docs"]);
    }

    #[test]
    fn srcinfo_malformed_line_names_the_line() {
        let err = parse_srcinfo("pkgbase = a\nnonsense line\n", "origin").unwrap_err();
        assert_eq!(err.line, Some(2));
        assert!(err.to_string().contains("origin:2"));
        assert!(err.to_string().contains("malformed .SRCINFO line"));
    }

    #[test]
    fn missing_fact_errors_name_recipe_and_fact() {
        let meta = RecipeMeta {
            id: RecipeId::new("bare").unwrap(),
            path: "packages/git/bare".to_string(),
            srcinfo: Some(Srcinfo {
                pkgbase: Some("bare".to_string()),
                ..Default::default()
            }),
            scanned: None,
            source: MetaSource::Srcinfo,
        };
        let err = meta.full_version().unwrap_err();
        assert!(err.to_string().contains("bare"));
        assert!(err.to_string().contains("missing fact 'pkgver'"));
    }

    #[test]
    fn scan_reads_literals_and_refuses_shell() {
        let scan = scan_pkgbuild(
            "pkgname=hello\n\
             pkgver=1.2\n\
             pkgrel=1\n\
             pkgdesc=\"a $(literal) description\"\n\
             depends=(glibc 'gcc-libs' $pkgbase)\n\
             pkgver() { git describe --tags }\n\
             build() {\n\
               make\n\
             }\n\
             source=()\n",
        );
        assert_eq!(
            scan.vars.get("pkgname"),
            Some(&ScanValue::Scalar("hello".to_string()))
        );
        assert_eq!(
            scan.vars.get("pkgver"),
            Some(&ScanValue::Scalar("1.2".to_string()))
        );
        assert!(scan.dynamic.contains("pkgdesc"));
        assert!(scan.dynamic.contains("depends"));
        assert!(scan.functions.contains("pkgver"));
        assert!(scan.functions.contains("build"));
        // The function body's shell was skipped: `make` is not a fact.
        assert!(!scan.vars.contains_key("make"));
    }

    #[test]
    fn scan_handles_multiline_arrays() {
        let scan = scan_pkgbuild("depends=(\n  glibc\n  zlib\n)\n");
        assert_eq!(
            scan.vars.get("depends"),
            Some(&ScanValue::Array(vec![
                "glibc".to_string(),
                "zlib".to_string()
            ]))
        );
    }

    #[test]
    fn scan_fact_is_strict() {
        let meta = RecipeMeta {
            id: RecipeId::new("hello").unwrap(),
            path: "packages/git/hello".to_string(),
            srcinfo: None,
            scanned: Some(scan_pkgbuild(
                "pkgname=hello\npkgver=$(git describe)\npkgrel=1\n",
            )),
            source: MetaSource::Scan,
        };
        assert_eq!(meta.pkgnames(), vec!["hello"]);
        // pkgver is shell-dynamic: refusing is the strict answer.
        let err = meta.full_version().unwrap_err();
        assert!(err.to_string().contains("missing fact 'pkgver'"));
    }

    #[test]
    fn source_classification_covers_vcs_remote_local_and_alias() {
        assert_eq!(
            classify_source("git+https://github.com/x/y.git").kind,
            SourceKind::Vcs(VcsKind::Git)
        );
        assert_eq!(
            classify_source("git://host/x").kind,
            SourceKind::Vcs(VcsKind::Git)
        );
        assert_eq!(
            classify_source("hg+https://host/x").kind,
            SourceKind::Vcs(VcsKind::Hg)
        );
        assert_eq!(
            classify_source("https://host/x.tar.zst").kind,
            SourceKind::Remote
        );
        assert_eq!(classify_source("fix.patch").kind, SourceKind::Local);
        let aliased = classify_source("desktop::git+https://github.com/zen-browser/desktop.git");
        assert_eq!(aliased.name.as_deref(), Some("desktop"));
        assert_eq!(aliased.kind, SourceKind::Vcs(VcsKind::Git));
    }

    #[test]
    fn arbitrary_bytes_never_panic() {
        let mut state: u64 = 0xd1b5_4a32_d192_ed03;
        for _ in 0..2000 {
            let mut next = || {
                state ^= state << 13;
                state ^= state >> 7;
                state ^= state << 17;
                state
            };
            let len = (next() % 128) as usize;
            let bytes: Vec<u8> = (0..len).map(|_| (next() & 0xff) as u8).collect();
            let text = String::from_utf8_lossy(&bytes).into_owned();
            let _ = parse_srcinfo_bytes(&bytes, "fuzz");
            let scan = scan_pkgbuild(&text);
            // Every scanned value stays answerable-or-refused, never a panic.
            let meta = RecipeMeta {
                id: RecipeId::new("fuzz").unwrap(),
                path: "fuzz".to_string(),
                srcinfo: None,
                scanned: Some(scan),
                source: MetaSource::Scan,
            };
            let _ = meta.pkgnames();
            let _ = meta.full_version();
            let _ = meta.sources();
            for fact in ["pkgname", "pkgver", "pkgrel", "pkgdesc", "epoch"] {
                let _ = meta.scan_fact(fact);
            }
        }
    }
}
