//! Strict loaders for the project's declarative configuration.
//!
//! One topology record per package (`id|path|groups|edges[|tags]`), plus
//! `build-defaults.conf`, `abi-exclusions.conf` and the optional user sets
//! under `config/sets/`. The loader contract is the fish engine's
//! (`build-all.fish:481-710`, plan-native-pm.md §3.3 "verbatim semantics"):
//! ONE malformed record breaks every command and the refusal names the
//! offender and its line. A registry that silently misparses is exactly the
//! silent gap strict loading exists to prevent.
//!
//! The filesystem is reached only through [`RecipeProbe`] (PKGBUILD
//! existence) and [`load_project`], so every parser is unit-testable in
//! memory and fuzz-safe: arbitrary bytes produce a structured error, never a
//! panic.

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};

use gsa_model::{Group, RecipeId, Tag, TopologyRecord};

/// A configuration refusal: always names its file, and its line when the
/// offender lives on one.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TopologyError {
    pub file: String,
    pub line: Option<usize>,
    pub message: String,
}

impl TopologyError {
    fn at(file: &str, line: usize, message: impl Into<String>) -> Self {
        TopologyError {
            file: file.to_string(),
            line: Some(line),
            message: message.into(),
        }
    }

    fn whole(file: &str, message: impl Into<String>) -> Self {
        TopologyError {
            file: file.to_string(),
            line: None,
            message: message.into(),
        }
    }
}

impl std::fmt::Display for TopologyError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self.line {
            Some(n) => write!(f, "{}:{}: {}", self.file, n, self.message),
            None => write!(f, "{}: {}", self.file, self.message),
        }
    }
}

impl std::error::Error for TopologyError {}

/// Existence check for a record path's `PKGBUILD`, injectable so the strict
/// parsers never need a filesystem to be tested.
pub trait RecipeProbe {
    fn pkgbuild_exists(&self, rel_path: &str) -> bool;
}

/// Production probe: `root/<rel_path>/PKGBUILD` must be a file.
pub struct FsProbe<'a> {
    pub root: &'a Path,
}

impl RecipeProbe for FsProbe<'_> {
    fn pkgbuild_exists(&self, rel_path: &str) -> bool {
        self.root.join(rel_path).join("PKGBUILD").is_file()
    }
}

/// Test probe answering uniformly without touching a filesystem.
pub struct ConstProbe(pub bool);

impl RecipeProbe for ConstProbe {
    fn pkgbuild_exists(&self, _rel_path: &str) -> bool {
        self.0
    }
}

const GROUP_ROSTER: &str = "git,stable,core,misc,app,build-tools";

fn valid_id_chars(s: &str) -> bool {
    !s.is_empty()
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-' | '+'))
}

/// The loaded topology: records in file order plus the indexes the loader
/// validated (unique ids, resolvable build-order edges).
#[derive(Clone, Debug, Default)]
pub struct Topology {
    pub records: Vec<TopologyRecord>,
    by_id: HashMap<String, usize>,
    group_members: BTreeMap<Group, Vec<RecipeId>>,
}

impl Topology {
    pub fn get(&self, id: &str) -> Option<&TopologyRecord> {
        self.by_id.get(id).map(|&i| &self.records[i])
    }

    pub fn index_of(&self, id: &str) -> Option<usize> {
        self.by_id.get(id).copied()
    }

    /// Group members in topology record order (never inferred from paths).
    pub fn members(&self, group: Group) -> &[RecipeId] {
        self.group_members
            .get(&group)
            .map(|v| v.as_slice())
            .unwrap_or(&[])
    }
}

/// Parse `config/topology.conf` content with full strict-loader semantics.
///
/// Rules, in order (each names the offender and its line):
/// `id|path|groups|edges[|tags]` with 4 or 5 `|`-fields; id charset
/// `A-Za-z0-9._+-`; unique ids; path relative (no leading `/`, no `..`) and
/// its `PKGBUILD` must exist; at least one group from the closed roster, no
/// repeats; edge names unique and every edge target a known record; tags from
/// the closed vocabulary, no repeats, never both `abi=must` and `abi=should`,
/// at most one `app-cluster=<name>`.
pub fn parse_topology(
    content: &str,
    file: &str,
    probe: &dyn RecipeProbe,
) -> Result<Topology, TopologyError> {
    let mut topo = Topology::default();
    for (idx, raw_line) in content.lines().enumerate() {
        let line_no = idx + 1;
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let fields: Vec<&str> = line.split('|').collect();
        if fields.len() < 4 || fields.len() > 5 {
            return Err(TopologyError::at(
                file,
                line_no,
                format!("invalid topology record (expected 'id|path|groups|edges[|tags]'): {line}"),
            ));
        }
        let id = fields[0];
        if !valid_id_chars(id) {
            return Err(TopologyError::at(
                file,
                line_no,
                format!("invalid topology record id '{id}' (allowed: A-Za-z0-9._+-): {line}"),
            ));
        }
        if topo.by_id.contains_key(id) {
            return Err(TopologyError::at(
                file,
                line_no,
                format!("duplicate package id in topology record: {id}"),
            ));
        }
        let path = fields[1];
        if path.starts_with('/')
            || path.contains("..")
            || path.is_empty()
            || !probe.pkgbuild_exists(path)
        {
            return Err(TopologyError::at(
                file,
                line_no,
                format!("invalid topology record path for {id}: {line}"),
            ));
        }
        // groups: closed roster, no repeats, at least one member.
        let mut groups: Vec<Group> = Vec::new();
        for grp in fields[2].split(',') {
            if grp.is_empty() {
                continue;
            }
            let Some(group) = Group::from_name(grp) else {
                return Err(TopologyError::at(
                    file,
                    line_no,
                    format!(
                        "unknown group in topology record {id}: {grp} (allowed: {GROUP_ROSTER})"
                    ),
                ));
            };
            if groups.contains(&group) {
                return Err(TopologyError::at(
                    file,
                    line_no,
                    format!("{grp} appears twice in the groups field of topology record {id}"),
                ));
            }
            groups.push(group);
        }
        if groups.is_empty() {
            return Err(TopologyError::at(
                file,
                line_no,
                format!("topology record for {id} names no group (allowed: {GROUP_ROSTER})"),
            ));
        }
        // Groups render in roster order on the data channel (contract §B.3).
        groups.sort_by_key(|g| {
            Group::ROSTER
                .iter()
                .position(|r| r == g)
                .unwrap_or(usize::MAX)
        });
        // edges: empty is valid and deliberate; repeats are drift.
        let mut edges: Vec<RecipeId> = Vec::new();
        for edge in fields[3].split(',') {
            if edge.is_empty() {
                continue;
            }
            if edges.iter().any(|e| e.as_str() == edge) {
                return Err(TopologyError::at(
                    file,
                    line_no,
                    format!("{edge} appears twice in the edges field of topology record {id}"),
                ));
            }
            let Ok(edge_id) = RecipeId::new(edge) else {
                return Err(TopologyError::at(
                    file,
                    line_no,
                    format!(
                        "invalid build-order edge '{edge}' in topology record {id} (allowed: A-Za-z0-9._+-)"
                    ),
                ));
            };
            edges.push(edge_id);
        }
        // tags: closed vocabulary, no repeats; at most one app-cluster; never
        // both abi severities. Unknown tags are refused, not ignored — a
        // typo'd batch tag would silently disable the batch gate.
        let mut tags: Vec<Tag> = Vec::new();
        if fields.len() == 5 {
            for tag in fields[4].split(',') {
                if tag.is_empty() {
                    continue;
                }
                let Some(parsed) = Tag::from_wire(tag) else {
                    return Err(TopologyError::at(
                        file,
                        line_no,
                        format!(
                            "unknown tag in topology record {id}: {tag} (allowed: abi=must,abi=should,abi-rev=<n>,app-cluster=<name>,version-sync=nvchecker)"
                        ),
                    ));
                };
                if tags.contains(&parsed) {
                    return Err(TopologyError::at(
                        file,
                        line_no,
                        format!("{tag} appears twice in the tags field of topology record {id}"),
                    ));
                }
                tags.push(parsed);
            }
            if tags.contains(&Tag::AbiMust) && tags.contains(&Tag::AbiShould) {
                return Err(TopologyError::at(
                    file,
                    line_no,
                    format!("topology record for {id} names both abi=must and abi=should"),
                ));
            }
            if tags
                .iter()
                .filter(|t| matches!(t, Tag::AppCluster(_)))
                .count()
                > 1
            {
                return Err(TopologyError::at(
                    file,
                    line_no,
                    format!("topology record for {id} names more than one app-cluster tag"),
                ));
            }
            // At most one abi-rev override: two revisions would make the
            // derived token ambiguous (the loader refuses, never picks one).
            if tags.iter().filter(|t| matches!(t, Tag::AbiRev(_))).count() > 1 {
                return Err(TopologyError::at(
                    file,
                    line_no,
                    format!("topology record for {id} names more than one abi-rev tag"),
                ));
            }
        }

        let record = TopologyRecord {
            id: RecipeId::new(id).map_err(|_| {
                TopologyError::at(file, line_no, format!("invalid topology record id '{id}'"))
            })?,
            path: path.to_string(),
            groups,
            edges,
            tags,
            source_line: line_no,
        };
        for group in &record.groups {
            topo.group_members
                .entry(*group)
                .or_default()
                .push(record.id.clone());
        }
        topo.by_id.insert(id.to_string(), topo.records.len());
        topo.records.push(record);
    }

    // Deferred pass: every id is now known, so edge targets are validated.
    // An edge names a build-order prerequisite — an unknown target is drift,
    // not a hint to be ignored.
    for record in &topo.records {
        for edge in &record.edges {
            if !topo.by_id.contains_key(edge.as_str()) {
                return Err(TopologyError::at(
                    file,
                    record.source_line,
                    format!(
                        "topology record for {} names an unknown build-order edge target: {}",
                        record.id, edge
                    ),
                ));
            }
        }
    }
    Ok(topo)
}

/// Runtime defaults (`config/build-defaults.conf`): one `key=value` per line.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BuildDefaults {
    pub lanes: String,
    pub jobs: String,
    pub intensity: String,
    pub memory_per_job_gib: String,
    pub core_memory_per_job_gib: String,
    pub reserved_memory_gib: String,
    pub state_dir: String,
}

impl Default for BuildDefaults {
    fn default() -> Self {
        BuildDefaults {
            lanes: "auto".to_string(),
            jobs: "auto".to_string(),
            intensity: "xhigh".to_string(),
            memory_per_job_gib: "3".to_string(),
            core_memory_per_job_gib: "4".to_string(),
            reserved_memory_gib: "2".to_string(),
            state_dir: "auto".to_string(),
        }
    }
}

/// The intensity roster (`docs/portability.md`; `configure_intensity`).
pub const INTENSITY_LEVELS: [&str; 5] = ["low", "medium", "high", "xhigh", "max"];

/// Parse `config/build-defaults.conf` content. Shape errors and unknown keys
/// break every command naming the offender; values are validated against
/// their vocabulary so a bad value cannot hide until a run misreads it
/// (the fish loader stored raw strings).
pub fn parse_build_defaults(content: &str, file: &str) -> Result<BuildDefaults, TopologyError> {
    let mut defaults = BuildDefaults::default();
    for (idx, raw_line) in content.lines().enumerate() {
        let line_no = idx + 1;
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            return Err(TopologyError::at(
                file,
                line_no,
                format!("invalid build defaults line (expected 'key=value'): {line}"),
            ));
        };
        let value = value.trim();
        if value.is_empty() {
            return Err(TopologyError::at(
                file,
                line_no,
                format!("empty value in build defaults line: {line}"),
            ));
        }
        let slot = match key {
            "lanes" => &mut defaults.lanes,
            "jobs" => &mut defaults.jobs,
            "intensity" => &mut defaults.intensity,
            "memory_per_job_gib" => &mut defaults.memory_per_job_gib,
            "core_memory_per_job_gib" => &mut defaults.core_memory_per_job_gib,
            "reserved_memory_gib" => &mut defaults.reserved_memory_gib,
            "state_dir" => &mut defaults.state_dir,
            _ => {
                return Err(TopologyError::at(
                    file,
                    line_no,
                    format!("unknown key in build defaults line: {line}"),
                ))
            }
        };
        match key {
            "lanes" | "jobs" => {
                let ok = value == "auto" || value.parse::<u32>().map(|n| n > 0).unwrap_or(false);
                if !ok {
                    return Err(TopologyError::at(
                        file,
                        line_no,
                        format!("invalid value for {key} (expected 'auto' or a positive count): {value}"),
                    ));
                }
            }
            "intensity" => {
                if !INTENSITY_LEVELS.contains(&value) {
                    return Err(TopologyError::at(
                        file,
                        line_no,
                        format!(
                            "invalid value for intensity (expected one of {}): {value}",
                            INTENSITY_LEVELS.join(",")
                        ),
                    ));
                }
            }
            "memory_per_job_gib" | "core_memory_per_job_gib" | "reserved_memory_gib" => {
                let ok = value
                    .parse::<f64>()
                    .map(|v| v.is_finite() && v > 0.0)
                    .unwrap_or(false);
                if !ok {
                    return Err(TopologyError::at(
                        file,
                        line_no,
                        format!("invalid value for {key} (expected a positive number): {value}"),
                    ));
                }
            }
            _ => {}
        }
        *slot = value.to_string();
    }
    Ok(defaults)
}

/// One documented ABI-guard exception (`config/abi-exclusions.conf`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AbiExclusion {
    pub id: String,
    pub reason: String,
    pub review_by: String,
    pub line: usize,
}

/// Parse `config/abi-exclusions.conf` content: `id|reason|review-by` per
/// line, strict; the loader validates the shape but does not enforce the
/// review date (the file's own header is the normative format doc).
pub fn parse_abi_exclusions(content: &str, file: &str) -> Result<Vec<AbiExclusion>, TopologyError> {
    let mut out = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for (idx, raw_line) in content.lines().enumerate() {
        let line_no = idx + 1;
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let fields: Vec<&str> = line.split('|').collect();
        if fields.len() != 3 {
            return Err(TopologyError::at(
                file,
                line_no,
                "invalid abi-exclusions entry (expected 'id|reason|review-by')",
            ));
        }
        let id = fields[0].trim();
        let reason = fields[1].trim();
        let review_by = fields[2].trim();
        if !valid_id_chars(id) {
            return Err(TopologyError::at(
                file,
                line_no,
                format!("invalid abi-exclusions id '{id}' (allowed: A-Za-z0-9._+-)"),
            ));
        }
        if reason.is_empty() {
            return Err(TopologyError::at(
                file,
                line_no,
                format!("abi-exclusions entry {id} has no reason"),
            ));
        }
        let iso = {
            let parts: Vec<&str> = review_by.split('-').collect();
            parts.len() == 3
                && parts[0].len() == 4
                && parts[1].len() == 2
                && parts[2].len() == 2
                && parts
                    .iter()
                    .all(|p| !p.is_empty() && p.chars().all(|c| c.is_ascii_digit()))
        };
        if !iso {
            return Err(TopologyError::at(
                file,
                line_no,
                format!("abi-exclusions entry {id} has no ISO review-by date"),
            ));
        }
        if seen.iter().any(|s| s == id) {
            return Err(TopologyError::at(
                file,
                line_no,
                format!("duplicate abi-exclusions id: {id}"),
            ));
        }
        seen.push(id.to_string());
        out.push(AbiExclusion {
            id: id.to_string(),
            reason: reason.to_string(),
            review_by: review_by.to_string(),
            line: line_no,
        });
    }
    Ok(out)
}

/// A user set (`config/sets/<name>`): a named selection sharing the `@`
/// namespace with groups (contract §C.2). Members are reference strings
/// resolved by the selection layer, which names the set when one is a typo.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UserSet {
    pub name: String,
    pub members: Vec<String>,
}

/// Parse one set file's content. Refs are kept verbatim (one per line).
pub fn parse_set_file(name: &str, content: &str, file: &str) -> Result<UserSet, TopologyError> {
    if !valid_id_chars(name) {
        return Err(TopologyError::whole(
            file,
            format!("invalid set name '{name}' (allowed: A-Za-z0-9._+-)"),
        ));
    }
    let mut members = Vec::new();
    for (idx, raw_line) in content.lines().enumerate() {
        let line_no = idx + 1;
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if line.contains(|c: char| c.is_control()) {
            return Err(TopologyError::at(
                file,
                line_no,
                "control character in set member reference".to_string(),
            ));
        }
        members.push(line.to_string());
    }
    Ok(UserSet {
        name: name.to_string(),
        members,
    })
}

/// Everything the engine reads from `config/`.
#[derive(Clone, Debug)]
pub struct ProjectConfig {
    pub root: PathBuf,
    pub topology: Topology,
    pub defaults: BuildDefaults,
    pub abi_exclusions: Vec<AbiExclusion>,
    pub sets: Vec<UserSet>,
}

impl ProjectConfig {
    pub fn set(&self, name: &str) -> Option<&UserSet> {
        self.sets.iter().find(|s| s.name == name)
    }

    /// The `@` namespace: a name resolving to both a group and a user set is
    /// a configuration error (contract §C.2).
    pub fn validate_namespace(&self) -> Result<(), TopologyError> {
        for set in &self.sets {
            if Group::from_name(&set.name).is_some() {
                return Err(TopologyError::whole(
                    "config/sets",
                    format!(
                        "set '{}' collides with a group name — the @ namespace must be unambiguous",
                        set.name
                    ),
                ));
            }
        }
        Ok(())
    }
}

fn read_file(path: &Path) -> Result<String, TopologyError> {
    std::fs::read_to_string(path).map_err(|e| {
        TopologyError::whole(
            path.to_string_lossy().as_ref(),
            format!("cannot read configuration file: {e}"),
        )
    })
}

/// Load the whole `config/` directory with strict-loader semantics: one
/// malformed record anywhere breaks every command. `abi-exclusions.conf` and
/// `config/sets/` may be absent (empty registry / no sets); the two required
/// files must parse.
pub fn load_project(root: &Path) -> Result<ProjectConfig, TopologyError> {
    let config_dir = root.join("config");
    let topology_path = config_dir.join("topology.conf");
    if !topology_path.is_file() {
        return Err(TopologyError::whole(
            topology_path.to_string_lossy().as_ref(),
            "topology file not found (run inside the recipe repository)",
        ));
    }
    let topology = parse_topology(
        &read_file(&topology_path)?,
        "config/topology.conf",
        &FsProbe { root },
    )?;

    let defaults_path = config_dir.join("build-defaults.conf");
    let defaults = parse_build_defaults(&read_file(&defaults_path)?, "config/build-defaults.conf")?;

    let exclusions_path = config_dir.join("abi-exclusions.conf");
    let abi_exclusions = if exclusions_path.is_file() {
        parse_abi_exclusions(&read_file(&exclusions_path)?, "config/abi-exclusions.conf")?
    } else {
        Vec::new()
    };

    let sets_dir = config_dir.join("sets");
    let mut sets = Vec::new();
    if sets_dir.is_dir() {
        let mut entries: Vec<PathBuf> = std::fs::read_dir(&sets_dir)
            .map_err(|e| {
                TopologyError::whole(
                    sets_dir.to_string_lossy().as_ref(),
                    format!("cannot read sets directory: {e}"),
                )
            })?
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.is_file())
            .collect();
        entries.sort();
        for path in entries {
            let name = path
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default();
            let file = format!("config/sets/{name}");
            sets.push(parse_set_file(&name, &read_file(&path)?, &file)?);
        }
    }

    let project = ProjectConfig {
        root: root.to_path_buf(),
        topology,
        defaults,
        abi_exclusions,
        sets,
    };
    project.validate_namespace()?;
    Ok(project)
}

#[cfg(test)]
mod tests {
    use super::*;

    const VALID: &str = "\
# comment
alpha|packages/git/alpha|git|
beta|packages/stable/beta|stable|alpha
gamma|packages/core/gamma|core,build-tools|alpha,beta|abi=must
delta|packages/app/delta|app|beta|app-cluster=qt5,version-sync=nvchecker
";

    #[test]
    fn valid_records_load() {
        let topo = parse_topology(VALID, "config/topology.conf", &ConstProbe(true)).unwrap();
        assert_eq!(topo.records.len(), 4);
        assert_eq!(topo.members(Group::Git).len(), 1);
        assert_eq!(topo.members(Group::BuildTools)[0].as_str(), "gamma");
        assert_eq!(topo.get("beta").unwrap().edges[0].as_str(), "alpha");
        assert_eq!(topo.get("gamma").unwrap().source_line, 4);
        // Data channel: five fields, groups in roster order.
        assert_eq!(
            topo.get("gamma").unwrap().wire(),
            "gamma|packages/core/gamma|core,build-tools|alpha,beta|abi=must"
        );
        assert_eq!(
            topo.get("alpha").unwrap().wire(),
            "alpha|packages/git/alpha|git||"
        );
    }

    fn reject(content: &str, needle: &str) -> TopologyError {
        let err = parse_topology(content, "config/topology.conf", &ConstProbe(true))
            .expect_err("record must be refused");
        assert!(
            err.to_string().contains(needle),
            "refusal {} must contain {needle:?}",
            err
        );
        // Every refusal names the offender and its line.
        assert!(
            err.to_string().starts_with("config/topology.conf:"),
            "refusal {} must name the file",
            err
        );
        assert!(err.line.is_some(), "refusal {} must name a line", err);
        err
    }

    #[test]
    fn malformed_records_are_refused_with_offender_and_line() {
        reject(
            "alpha|packages/git/alpha\n",
            "expected 'id|path|groups|edges[|tags]'",
        );
        reject(
            "bad id|packages/git/x|git|\n",
            "invalid topology record id 'bad id'",
        );
        reject(
            "alpha|/abs/path|git|\nalpha|packages/git/alpha|git|\n",
            "invalid topology record path for alpha",
        );
        reject(
            "alpha|packages/git/alpha|git|\nalpha|packages/git/alpha|git|\n",
            "duplicate package id in topology record: alpha",
        );
        reject("alpha|packages/git/alpha||\n", "names no group");
        reject(
            "alpha|packages/git/alpha|nope|\n",
            "unknown group in topology record alpha: nope",
        );
        reject(
            "alpha|packages/git/alpha|git,git|\n",
            "git appears twice in the groups field",
        );
        reject(
            "alpha|packages/git/alpha|git|alpha,alpha\n",
            "alpha appears twice in the edges field",
        );
        reject(
            "alpha|packages/git/alpha|git|ghost\n",
            "names an unknown build-order edge target: ghost",
        );
        reject(
            "alpha|packages/git/alpha|git||abi=maybe\n",
            "unknown tag in topology record alpha: abi=maybe",
        );
        reject(
            "alpha|packages/git/alpha|git||abi=must,abi=should\n",
            "names both abi=must and abi=should",
        );
        reject(
            "alpha|packages/git/alpha|git||app-cluster=a,app-cluster=b\n",
            "names more than one app-cluster tag",
        );
        let err = reject(
            "ok|packages/git/ok|git|\nok|packages/git/ok|git|\n",
            "duplicate package id in topology record: ok",
        );
        assert_eq!(err.line, Some(2));
    }

    #[test]
    fn missing_pkgbuild_is_refused() {
        let err = parse_topology(
            "alpha|packages/git/alpha|git|\n",
            "config/topology.conf",
            &ConstProbe(false),
        )
        .unwrap_err();
        assert!(err
            .to_string()
            .contains("invalid topology record path for alpha"));
    }

    #[test]
    fn build_defaults_parse_and_validate() {
        let ok = parse_build_defaults(
            "lanes=auto\njobs=4\nintensity=xhigh\nmemory_per_job_gib=3\nstate_dir=auto\n",
            "config/build-defaults.conf",
        )
        .unwrap();
        assert_eq!(ok.lanes, "auto");
        assert_eq!(ok.jobs, "4");
        let err = parse_build_defaults("bogus=1\n", "config/build-defaults.conf").unwrap_err();
        assert!(err.to_string().contains("config/build-defaults.conf:1"));
        assert!(err.to_string().contains("unknown key"));
        let err = parse_build_defaults("lanes\n", "config/build-defaults.conf").unwrap_err();
        assert!(err.to_string().contains("expected 'key=value'"));
        let err = parse_build_defaults("intensity=ludicrous\n", "config/build-defaults.conf")
            .unwrap_err();
        assert!(err.to_string().contains("invalid value for intensity"));
    }

    #[test]
    fn abi_exclusions_parse_and_validate() {
        let rows = parse_abi_exclusions(
            "# seed\nlinux-headers|kernel header payload|2027-04-01\n",
            "config/abi-exclusions.conf",
        )
        .unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].id, "linux-headers");
        assert!(parse_abi_exclusions("a|b|\n", "f")
            .unwrap_err()
            .to_string()
            .contains("no ISO review-by date"));
        assert!(parse_abi_exclusions("a||2027-04-01\n", "f")
            .unwrap_err()
            .to_string()
            .contains("has no reason"));
        assert!(
            parse_abi_exclusions("a|b|2027-04-01\na|b|2027-04-01\n", "f")
                .unwrap_err()
                .to_string()
                .contains("duplicate abi-exclusions id: a")
        );
    }

    #[test]
    fn set_files_parse_and_namespaces_stay_unambiguous() {
        let set = parse_set_file("mine", "# pick\nalpha\nbeta\n", "config/sets/mine").unwrap();
        assert_eq!(set.members, vec!["alpha", "beta"]);
        let mut topo = Topology::default();
        topo.records.push(TopologyRecord {
            id: RecipeId::new("alpha").unwrap(),
            path: "packages/git/alpha".to_string(),
            groups: vec![Group::Git],
            edges: vec![],
            tags: vec![],
            source_line: 1,
        });
        let project = ProjectConfig {
            root: PathBuf::from("."),
            topology: topo,
            defaults: BuildDefaults::default(),
            abi_exclusions: vec![],
            sets: vec![UserSet {
                name: "git".to_string(),
                members: vec![],
            }],
        };
        assert!(project
            .validate_namespace()
            .unwrap_err()
            .to_string()
            .contains("collides with a group name"));
    }

    #[test]
    fn arbitrary_bytes_never_panic() {
        // Deterministic xorshift fuzz: every parser must answer with a
        // structured result, never a panic.
        let mut state: u64 = 0x9e37_79b9_7f4a_7c15;
        for _ in 0..2000 {
            let mut next = || {
                state ^= state << 13;
                state ^= state >> 7;
                state ^= state << 17;
                state
            };
            let len = (next() % 96) as usize;
            let bytes: Vec<u8> = (0..len).map(|_| (next() & 0xff) as u8).collect();
            let text = String::from_utf8_lossy(&bytes).into_owned();
            let _ = parse_topology(&text, "fuzz", &ConstProbe(true));
            let _ = parse_build_defaults(&text, "fuzz");
            let _ = parse_abi_exclusions(&text, "fuzz");
            let _ = parse_set_file("set", &text, "fuzz");
        }
    }
}
