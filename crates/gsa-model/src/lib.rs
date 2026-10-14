//! Core types of the native `gsa` engine (`docs/gsa-contract.md`).
//!
//! `gsa-model` owns the typed vocabulary every other crate shares: recipe
//! identity, topology records, and the run record (`format: 2`, contract §H)
//! with its plan rows, outcome rows and enums (§E–§G). The machine rendering
//! of the run record lives beside the type it renders — the "one record,
//! three renderings" seam of ADR 0003: the typed structure is computed once
//! and the dashboard, prose and machine block are views of it. Phase 1 emits
//! the machine block and a prose view from `gsa-cli`; the dashboard lands
//! with the scheduler (`gsa-sched`, plan-native-pm.md §3.1).
//!
//! Nothing here evaluates recipes or reads the filesystem: this crate is
//! pure data and rendering.

use std::fmt;

use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// Recipe identity
// ---------------------------------------------------------------------------

/// A recipe id as it appears in `config/topology.conf` (allowed characters:
/// `A-Za-z0-9._+-`, contract §C.1 / the strict loader's id rule).
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub struct RecipeId(String);

/// The string supplied where a recipe id was required is not a valid id.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InvalidRecipeId(pub String);

impl RecipeId {
    pub fn new(s: impl Into<String>) -> Result<Self, InvalidRecipeId> {
        let s = s.into();
        let ok = !s.is_empty()
            && s.chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-' | '+'));
        if ok {
            Ok(Self(s))
        } else {
            Err(InvalidRecipeId(s))
        }
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for RecipeId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl AsRef<str> for RecipeId {
    fn as_ref(&self) -> &str {
        self.as_str()
    }
}

// ---------------------------------------------------------------------------
// Groups and topology tags
// ---------------------------------------------------------------------------

/// A scheduling class. Membership is stated by the topology record only and
/// never inferred from directory names (`docs/architecture.md`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub enum Group {
    Git,
    Stable,
    Core,
    Misc,
    App,
    BuildTools,
}

impl Group {
    /// The closed roster, in canonical (wire) order.
    pub const ROSTER: [Group; 6] = [
        Group::Git,
        Group::Stable,
        Group::Core,
        Group::Misc,
        Group::App,
        Group::BuildTools,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Group::Git => "git",
            Group::Stable => "stable",
            Group::Core => "core",
            Group::Misc => "misc",
            Group::App => "app",
            Group::BuildTools => "build-tools",
        }
    }

    pub fn from_name(name: &str) -> Option<Group> {
        Group::ROSTER.into_iter().find(|g| g.as_str() == name)
    }
}

impl fmt::Display for Group {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// A topology tag. The vocabulary is closed (the strict loader refuses
/// anything else, so a typo'd batch tag cannot silently disable a gate).
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub enum Tag {
    /// Coupled batch: the ABI must move in one rebuild pass.
    AbiMust,
    /// Coupled batch, advisory severity.
    AbiShould,
    /// `app-cluster=<name>`: these records present as ONE row in the app
    /// prompt. Presentation only — the packages stay separate everywhere else.
    AppCluster(String),
    /// `version-sync=nvchecker`: explicit build-time provider opt-in.
    VersionSyncNvchecker,
    /// `abi-rev=<n>`: the declared ABI-revision override (contract §J.4,
    /// plan-native-pm.md §4.1) — for ABI moves derivation cannot see (LLVM
    /// C++ snapshots, Qt private API). Participates in the derived abi-token
    /// so a revision bump alone moves the token.
    AbiRev(u64),
}

impl Tag {
    pub fn from_wire(s: &str) -> Option<Tag> {
        match s {
            "abi=must" => Some(Tag::AbiMust),
            "abi=should" => Some(Tag::AbiShould),
            "version-sync=nvchecker" => Some(Tag::VersionSyncNvchecker),
            _ => {
                if let Some(rev) = s.strip_prefix("abi-rev=") {
                    // Strict: decimal digits only, no empty value — a
                    // malformed override must refuse the record, never
                    // silently drop out of the token.
                    if !rev.is_empty() && rev.bytes().all(|b| b.is_ascii_digit()) {
                        return rev.parse::<u64>().ok().map(Tag::AbiRev);
                    }
                    return None;
                }
                let name = s.strip_prefix("app-cluster=")?;
                if !name.is_empty()
                    && name
                        .chars()
                        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-' | '+'))
                {
                    Some(Tag::AppCluster(name.to_string()))
                } else {
                    None
                }
            }
        }
    }

    pub fn to_wire(&self) -> String {
        match self {
            Tag::AbiMust => "abi=must".to_string(),
            Tag::AbiShould => "abi=should".to_string(),
            Tag::VersionSyncNvchecker => "version-sync=nvchecker".to_string(),
            Tag::AppCluster(name) => format!("app-cluster={name}"),
            Tag::AbiRev(n) => format!("abi-rev={n}"),
        }
    }
}

impl fmt::Display for Tag {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.to_wire())
    }
}

/// One topology record: `id|path|groups|edges[|tags]` (contract §B.3 `-Qt`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TopologyRecord {
    pub id: RecipeId,
    pub path: String,
    pub groups: Vec<Group>,
    /// Build-order edges: this recipe consumes each named recipe, so every
    /// named recipe builds first. Not pacman dependencies (`CONTEXT.md`).
    pub edges: Vec<RecipeId>,
    pub tags: Vec<Tag>,
    /// 1-based line of the record in `config/topology.conf`, kept so every
    /// refusal can name the offender *and* its line (contract §C.5).
    pub source_line: usize,
}

impl TopologyRecord {
    /// The tooling data channel row: exactly five `|`-separated fields,
    /// groups in roster order, edges and tags in record order.
    pub fn wire(&self) -> String {
        let groups = self
            .groups
            .iter()
            .map(|g| g.as_str())
            .collect::<Vec<_>>()
            .join(",");
        let edges = self
            .edges
            .iter()
            .map(|e| e.as_str())
            .collect::<Vec<_>>()
            .join(",");
        let tags = self
            .tags
            .iter()
            .map(|t| t.to_wire())
            .collect::<Vec<_>>()
            .join(",");
        format!("{}|{}|{}|{}|{}", self.id, self.path, groups, edges, tags)
    }
}

// ---------------------------------------------------------------------------
// Outcome and decision vocabularies (contract §F, §E)
// ---------------------------------------------------------------------------

/// Lane outcome codes (contract §F.1). Stable wire values.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum LaneOutcome {
    Ok,
    Failed,
    Parked,
    Defer,
    Lost,
    Hup,
    Int,
    Term,
}

impl LaneOutcome {
    pub fn code(self) -> i32 {
        match self {
            LaneOutcome::Ok => 0,
            LaneOutcome::Failed => 1,
            LaneOutcome::Parked => 98,
            LaneOutcome::Defer => 99,
            LaneOutcome::Lost => 125,
            LaneOutcome::Hup => 129,
            LaneOutcome::Int => 130,
            LaneOutcome::Term => 143,
        }
    }

    pub fn from_code(code: i32) -> Option<LaneOutcome> {
        use LaneOutcome::*;
        [Ok, Failed, Parked, Defer, Lost, Hup, Int, Term]
            .into_iter()
            .find(|o| o.code() == code)
    }
}

/// The planned action of a plan row (contract §H.2).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum PlanAction {
    Build,
    BuildInstall,
    Install,
    Fetch,
    Skip,
    Parked,
    Refused,
    Noop,
}

impl PlanAction {
    pub fn as_str(self) -> &'static str {
        match self {
            PlanAction::Build => "build",
            PlanAction::BuildInstall => "build-install",
            PlanAction::Install => "install",
            PlanAction::Fetch => "fetch",
            PlanAction::Skip => "skip",
            PlanAction::Parked => "parked",
            PlanAction::Refused => "refused",
            PlanAction::Noop => "noop",
        }
    }
}

impl fmt::Display for PlanAction {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// One plan row: `<pkg> <plan> <reason…>` (contract §H.2).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlanRow {
    pub pkg: RecipeId,
    pub action: PlanAction,
    pub reason: String,
}

/// An install decision (contract §E.3) — the seam vocabulary, distinct from
/// the run-record plan vocabulary on purpose (`refuse` here, `refused` there).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Decision {
    Install,
    Skip,
    Refuse,
    Noop,
    Parked,
}

impl Decision {
    pub fn as_str(self) -> &'static str {
        match self {
            Decision::Install => "install",
            Decision::Skip => "skip",
            Decision::Refuse => "refuse",
            Decision::Noop => "noop",
            Decision::Parked => "parked",
        }
    }
}

impl fmt::Display for Decision {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// One decision row: `<pkgbase> <decision> <reason…>` (contract §E.2).
/// Computed ONCE by the one decision seam (`docs/MEMORY.md` rule 20); the
/// seam's stdout, the run-record plan rows and the prose summary are three
/// renderings of these rows, never re-decisions.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct DecisionRow {
    pub subject: String,
    pub decision: Decision,
    pub reason: String,
}

impl DecisionRow {
    /// The §E.2 row rendering (the `--install-decide` stdout framing).
    pub fn render(&self) -> String {
        format!(
            "{} {} {}",
            self.subject,
            self.decision.as_str(),
            self.reason
        )
    }

    /// The run-record plan vocabulary this decision renders as (§H.2).
    pub fn plan_action(self) -> PlanAction {
        match self.decision {
            Decision::Install => PlanAction::Install,
            Decision::Skip => PlanAction::Skip,
            Decision::Refuse => PlanAction::Refused,
            Decision::Noop => PlanAction::Noop,
            Decision::Parked => PlanAction::Parked,
        }
    }
}

/// Run-record per-package status (contract §H.3).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum RowStatus {
    Succeeded,
    Failed,
    Deferred,
    Parked,
    NeverStarted,
    Interrupted,
}

impl RowStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            RowStatus::Succeeded => "succeeded",
            RowStatus::Failed => "failed",
            RowStatus::Deferred => "deferred",
            RowStatus::Parked => "parked",
            RowStatus::NeverStarted => "never-started",
            RowStatus::Interrupted => "interrupted",
        }
    }
}

impl fmt::Display for RowStatus {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// One outcome row: `<pkg> <status> <rc> <dur> <reason…>` (contract §H.2).
/// `rc` and `dur` are `-` when the package never produced one.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct OutcomeRow {
    pub pkg: RecipeId,
    pub status: RowStatus,
    pub rc: Option<i32>,
    pub dur: Option<i64>,
    pub reason: String,
}

/// The run-level outcome of the rows (contract §G.1), computed once from the
/// same rows every rendering shows. Precedence on a completed run: refusal
/// (3) > failure (4 or 1 per policy) > deferral-only (5) > success (0); a
/// signalled run — or a run carrying a signalled lane's `interrupted` row —
/// exits 130 regardless of earlier failures (§G.1).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RunOutcome {
    /// The `outcome:` scalar vocabulary: `planned` (dry run), `success`,
    /// `failed`, `deferral`, `interrupted`, `refused`.
    pub outcome: &'static str,
    /// The process exit code — and the record's `rc:` scalar, byte for byte.
    pub rc: i32,
}

impl RunOutcome {
    /// `fail_fast`: the run used `--fail-fast` (a failure there means
    /// dispatch stopped → rc 1; a cone-stop run's failure → rc 4).
    /// `interrupted`: a signal tore the run down (rc 130). `refused`: the
    /// run refused to start or aborted at a fail-closed gate (rc 3).
    pub fn compute(
        rows: &[OutcomeRow],
        fail_fast: bool,
        interrupted: bool,
        refused: bool,
    ) -> RunOutcome {
        let has = |status: RowStatus| rows.iter().any(|r| r.status == status);
        if interrupted || has(RowStatus::Interrupted) {
            // §G.1: a signalled run exits 130 regardless of earlier failures.
            // "Was signalled" is observable two ways: the supervisor tore the
            // run down (`interrupted`), or a lane reported a signal death (an
            // `interrupted` row, §F.1 codes 129/130/143) — either forces the
            // interrupt class.
            return RunOutcome {
                outcome: "interrupted",
                rc: 130,
            };
        }
        if refused {
            return RunOutcome {
                outcome: "refused",
                rc: 3,
            };
        }
        if has(RowStatus::Failed) {
            return RunOutcome {
                outcome: "failed",
                rc: if fail_fast { 1 } else { 4 },
            };
        }
        if has(RowStatus::Deferred) || has(RowStatus::Parked) {
            // §G.1: ≥1 deferred/parked row and no failed row — a deferral
            // exits non-zero without claiming a build failure.
            return RunOutcome {
                outcome: "deferral",
                rc: 5,
            };
        }
        RunOutcome {
            outcome: "success",
            rc: 0,
        }
    }
}

// ---------------------------------------------------------------------------
// Run record (contract §H, `format: 2`)
// ---------------------------------------------------------------------------

/// The continuation section (contract §H.2). Arguments come from one
/// flag-rule table with an explicit not-mirrored list; ambient environment
/// inputs are warned about (`env_required`), never baked in.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Continuation {
    pub command: String,
    pub remaining: Vec<RecipeId>,
    pub not_mirrored: Vec<String>,
    pub env_required: Vec<String>,
}

/// The one run record: plan + per-package outcome rows + continuation,
/// computed once and rendered as views (ADR 0003).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RunRecord {
    pub selection_source: String,
    pub order: Vec<RecipeId>,
    /// Resolved lane count. The machine block renders a non-negative integer
    /// ALWAYS (contract §H.2's strict grammar — the `format: 2` parser
    /// accepts nothing else): `None` — a record whose run dispatched no
    /// lanes (dry runs, `-U` transactions, preflight refusals) — renders `0`,
    /// never `-`. The `-` spelling is reserved for per-row `rc`/`dur`.
    pub lanes: Option<u32>,
    pub normal_jobs: Option<u32>,
    pub core_jobs: Option<u32>,
    pub intensity: String,
    /// Run-level outcome. `planned` is the dry-run value (no rows below
    /// claim an execution outcome); otherwise the §G.1 class of the rows.
    pub outcome: String,
    pub rc: i32,
    pub dry_run: bool,
    /// The additive `prefetch-warnings:` extension scalar (contract §H.2,
    /// owner decision 5 / docs/adr/0004-prefetch-advisory.md): the count of
    /// fetch-ahead advisory warnings of a build run. `None` when the run had
    /// no fetch-ahead participation (plan/txn records). Never rows, never a
    /// format bump.
    pub prefetch_warnings: Option<u32>,
    pub plan: Vec<PlanRow>,
    pub outcomes: Vec<OutcomeRow>,
    pub continuation: Continuation,
}

/// Machine value sanitation (contract §H.2): a value never contains a
/// newline, and no line ever starts with the `--- ` section marker.
fn scalar(value: &str) -> String {
    value
        .chars()
        .map(|c| if c == '\n' || c == '\r' { ' ' } else { c })
        .collect::<String>()
        .replace("--- ", "-- ")
}

fn opt_num<T: fmt::Display>(v: Option<T>) -> String {
    match v {
        Some(v) => v.to_string(),
        None => "-".to_string(),
    }
}

impl RunRecord {
    /// The `format: 2` machine block (contract §H.2). Printed to stdout
    /// after the run's other renderings; a parser reads this block and
    /// derives expectations from its rows (contract §L.3).
    pub fn render_machine(&self) -> String {
        let mut out = String::new();
        out.push_str("--- run record begin ---\n");
        out.push_str(&format!("format: 2\n"));
        out.push_str(&format!(
            "selection-source: {}\n",
            scalar(&self.selection_source)
        ));
        let order = self
            .order
            .iter()
            .map(|id| id.as_str())
            .collect::<Vec<_>>()
            .join(" ");
        out.push_str(&format!("order: {}\n", scalar(&order)));
        out.push_str(&format!("lanes: {}\n", self.lanes.unwrap_or(0)));
        out.push_str(&format!("normal-jobs: {}\n", self.normal_jobs.unwrap_or(0)));
        out.push_str(&format!("core-jobs: {}\n", self.core_jobs.unwrap_or(0)));
        out.push_str(&format!("intensity: {}\n", scalar(&self.intensity)));
        out.push_str(&format!("outcome: {}\n", scalar(&self.outcome)));
        out.push_str(&format!("rc: {}\n", self.rc));
        if self.dry_run {
            // Extension scalars may follow the fixed set without a format
            // bump (contract §H.2).
            out.push_str("dry-run: yes\n");
        }
        if let Some(count) = self.prefetch_warnings {
            out.push_str(&format!("prefetch-warnings: {count}\n"));
        }
        out.push_str("--- plan ---\n");
        for row in &self.plan {
            let reason = if row.reason.is_empty() {
                "-"
            } else {
                &row.reason
            };
            out.push_str(&format!(
                "{} {} {}\n",
                row.pkg,
                row.action.as_str(),
                scalar(reason)
            ));
        }
        out.push_str("--- outcome ---\n");
        for row in &self.outcomes {
            let reason = if row.reason.is_empty() {
                "-"
            } else {
                &row.reason
            };
            out.push_str(&format!(
                "{} {} {} {} {}\n",
                row.pkg,
                row.status.as_str(),
                opt_num(row.rc),
                opt_num(row.dur),
                scalar(reason)
            ));
        }
        out.push_str("--- continuation ---\n");
        out.push_str(&format!(
            "command: {}\n",
            scalar(&self.continuation.command)
        ));
        let remaining = self
            .continuation
            .remaining
            .iter()
            .map(|id| id.as_str())
            .collect::<Vec<_>>()
            .join(" ");
        out.push_str(&format!("remaining: {}\n", scalar(&remaining)));
        out.push_str(&format!(
            "not-mirrored: {}\n",
            scalar(&self.continuation.not_mirrored.join(" "))
        ));
        let env = if self.continuation.env_required.is_empty() {
            "-".to_string()
        } else {
            self.continuation.env_required.join(" ")
        };
        out.push_str(&format!("env-required: {}\n", scalar(&env)));
        out.push_str("--- run record end ---\n");
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn id(s: &str) -> RecipeId {
        RecipeId::new(s).unwrap()
    }

    #[test]
    fn recipe_id_charset_is_enforced() {
        assert!(RecipeId::new("mesa-git").is_ok());
        assert!(RecipeId::new("qt6.8+x_1").is_ok());
        assert!(RecipeId::new("").is_err());
        assert!(RecipeId::new("has space").is_err());
        assert!(RecipeId::new("bad|pipe").is_err());
    }

    #[test]
    fn tag_wire_round_trips() {
        for wire in [
            "abi=must",
            "abi=should",
            "version-sync=nvchecker",
            "app-cluster=qt5",
        ] {
            let tag = Tag::from_wire(wire).expect("known tag");
            assert_eq!(tag.to_wire(), wire);
        }
        assert!(Tag::from_wire("app-cluster=").is_none());
        assert!(Tag::from_wire("app-cluster=bad name").is_none());
        assert!(Tag::from_wire("abi=maybe").is_none());
    }

    #[test]
    fn topology_record_wire_has_five_fields() {
        let rec = TopologyRecord {
            id: id("mesa-git"),
            path: "packages/git/mesa-git".to_string(),
            groups: vec![Group::Git],
            edges: vec![id("llvm-git"), id("python")],
            tags: vec![Tag::AbiShould, Tag::VersionSyncNvchecker],
            source_line: 7,
        };
        assert_eq!(
            rec.wire(),
            "mesa-git|packages/git/mesa-git|git|llvm-git,python|abi=should,version-sync=nvchecker"
        );
        let bare = TopologyRecord {
            id: id("python"),
            path: "packages/stable/python".to_string(),
            groups: vec![Group::Stable],
            edges: vec![],
            tags: vec![],
            source_line: 1,
        };
        assert_eq!(bare.wire(), "python|packages/stable/python|stable||");
    }

    #[test]
    fn lane_outcome_codes_are_stable() {
        assert_eq!(LaneOutcome::Ok.code(), 0);
        assert_eq!(LaneOutcome::Failed.code(), 1);
        assert_eq!(LaneOutcome::Parked.code(), 98);
        assert_eq!(LaneOutcome::Defer.code(), 99);
        assert_eq!(LaneOutcome::Lost.code(), 125);
        assert_eq!(LaneOutcome::Hup.code(), 129);
        assert_eq!(LaneOutcome::Int.code(), 130);
        assert_eq!(LaneOutcome::Term.code(), 143);
        for code in [0, 1, 98, 99, 125, 129, 130, 143] {
            assert_eq!(LaneOutcome::from_code(code).unwrap().code(), code);
        }
        assert!(LaneOutcome::from_code(2).is_none());
    }

    fn sample_record(dry_run: bool) -> RunRecord {
        RunRecord {
            selection_source: "sets=@git leaf=no range=-".to_string(),
            order: vec![id("glib2-git"), id("gtk4-git")],
            lanes: None,
            normal_jobs: None,
            core_jobs: None,
            intensity: "xhigh".to_string(),
            outcome: "planned".to_string(),
            rc: 0,
            dry_run,
            prefetch_warnings: None,
            plan: vec![
                PlanRow {
                    pkg: id("glib2-git"),
                    action: PlanAction::BuildInstall,
                    reason: "ok".to_string(),
                },
                PlanRow {
                    pkg: id("gtk4-git"),
                    action: PlanAction::BuildInstall,
                    reason: "ok".to_string(),
                },
            ],
            outcomes: vec![
                OutcomeRow {
                    pkg: id("glib2-git"),
                    status: RowStatus::NeverStarted,
                    rc: None,
                    dur: None,
                    reason: "dry-run".to_string(),
                },
                OutcomeRow {
                    pkg: id("gtk4-git"),
                    status: RowStatus::NeverStarted,
                    rc: None,
                    dur: None,
                    reason: "dry-run".to_string(),
                },
            ],
            continuation: Continuation {
                command: "gsa -S --dry-run glib2-git gtk4-git".to_string(),
                remaining: vec![id("glib2-git"), id("gtk4-git")],
                not_mirrored: vec!["-Mc".to_string(), "-Mcc".to_string()],
                env_required: vec!["GSA_STATE_DIR".to_string()],
            },
        }
    }

    #[test]
    fn machine_block_grammar_is_rendered() {
        let block = sample_record(true).render_machine();
        let lines: Vec<&str> = block.lines().collect();
        assert_eq!(lines.first(), Some(&"--- run record begin ---"));
        assert_eq!(lines.last(), Some(&"--- run record end ---"));
        assert_eq!(lines[1], "format: 2");
        // Fixed scalar order first; the dry-run extension follows the fixed set.
        let keys: Vec<&str> = lines[2..10]
            .iter()
            .map(|l| l.split(": ").next().unwrap())
            .collect();
        assert_eq!(
            keys,
            [
                "selection-source",
                "order",
                "lanes",
                "normal-jobs",
                "core-jobs",
                "intensity",
                "outcome",
                "rc"
            ]
        );
        assert_eq!(lines[10], "dry-run: yes");
        // Budget scalars are ALWAYS integers (§H.2 strict grammar): a record
        // that dispatched no lanes renders 0, never `-`.
        assert_eq!(lines[4], "lanes: 0");
        assert_eq!(lines[5], "normal-jobs: 0");
        assert_eq!(lines[6], "core-jobs: 0");
        let plan_at = lines.iter().position(|l| *l == "--- plan ---").unwrap();
        let outcome_at = lines.iter().position(|l| *l == "--- outcome ---").unwrap();
        let cont_at = lines
            .iter()
            .position(|l| *l == "--- continuation ---")
            .unwrap();
        assert_eq!(lines[plan_at + 1], "glib2-git build-install ok");
        assert_eq!(lines[plan_at + 2], "gtk4-git build-install ok");
        assert_eq!(lines[outcome_at + 1], "glib2-git never-started - - dry-run");
        assert_eq!(lines[outcome_at + 2], "gtk4-git never-started - - dry-run");
        assert_eq!(
            lines[cont_at + 1],
            "command: gsa -S --dry-run glib2-git gtk4-git"
        );
        assert_eq!(lines[cont_at + 2], "remaining: glib2-git gtk4-git");
    }

    #[test]
    fn machine_values_never_break_the_grammar() {
        let mut rec = sample_record(true);
        rec.outcome = "weird\n--- plan ---".to_string();
        rec.plan[0].reason = "a\nb".to_string();
        let block = rec.render_machine();
        // The injected section marker is defanged and no value spans lines.
        assert!(block.contains("outcome: weird -- plan ---"));
        assert!(block.contains("glib2-git build-install a b"));
        assert_eq!(block.lines().filter(|l| *l == "--- plan ---").count(), 1);
    }

    fn row(pkg: &str, status: RowStatus, rc: Option<i32>, reason: &str) -> OutcomeRow {
        OutcomeRow {
            pkg: id(pkg),
            status,
            rc,
            dur: None,
            reason: reason.to_string(),
        }
    }

    #[test]
    fn exit_code_matrix_follows_section_g() {
        use RowStatus::*;
        let ok = row("a", Succeeded, Some(0), "ok");
        let failed = row("b", Failed, Some(1), "build-failed");
        let lost = row("c", Failed, Some(125), "lane-lost");
        let parked = row("d", Parked, None, "waits-on-failed");
        let deferred = row("e", Deferred, Some(99), "source-unfetchable");
        let wait = row("f", Parked, None, "waits-on-deferred");
        let interrupted = row("g", Interrupted, Some(130), "interrupted-mid-build");

        // success: everything succeeded.
        let out = RunOutcome::compute(&[ok.clone()], false, false, false);
        assert_eq!((out.outcome, out.rc), ("success", 0));
        // cone-stop run with ≥1 failure → 4 (§G.1 "Precise answer").
        let out = RunOutcome::compute(
            &[ok.clone(), failed.clone(), parked.clone()],
            false,
            false,
            false,
        );
        assert_eq!((out.outcome, out.rc), ("failed", 4));
        // even a leaf failure with zero parked rows is rc 4 under cone-stop.
        let out = RunOutcome::compute(&[failed.clone()], false, false, false);
        assert_eq!((out.outcome, out.rc), ("failed", 4));
        // a lost lane counts as a failure (rc 125 is a failed row).
        let out = RunOutcome::compute(&[lost], false, false, false);
        assert_eq!((out.outcome, out.rc), ("failed", 4));
        // --fail-fast failure → 1.
        let out = RunOutcome::compute(&[failed.clone()], true, false, false);
        assert_eq!((out.outcome, out.rc), ("failed", 1));
        // deferral-only → 5 (deferred row alone, or a parked-by-deferral row).
        let out = RunOutcome::compute(&[ok.clone(), deferred.clone()], false, false, false);
        assert_eq!((out.outcome, out.rc), ("deferral", 5));
        let out = RunOutcome::compute(&[wait], true, false, false);
        assert_eq!((out.outcome, out.rc), ("deferral", 5));
        // failure beats deferral in the precedence.
        let out = RunOutcome::compute(&[failed.clone(), deferred.clone()], false, false, false);
        assert_eq!((out.outcome, out.rc), ("failed", 4));
        // interrupt → 130 regardless of earlier failures (§G.1).
        let out = RunOutcome::compute(&[failed, interrupted], false, true, false);
        assert_eq!((out.outcome, out.rc), ("interrupted", 130));
        // refusal beats failures on a completed run.
        let out = RunOutcome::compute(&[ok], false, false, true);
        assert_eq!((out.outcome, out.rc), ("refused", 3));
    }

    #[test]
    fn a_signalled_lane_row_is_the_interrupt_class() {
        use RowStatus::*;
        let ok = row("a", Succeeded, Some(0), "ok");
        let signalled = row("b", Interrupted, Some(143), "interrupted-mid-build");
        // §G.1: a run that was signalled exits 130 with the record first —
        // a signalled lane row can never settle the run as `success` rc 0.
        let out = RunOutcome::compute(&[ok.clone(), signalled.clone()], false, false, false);
        assert_eq!(
            (out.outcome, out.rc),
            ("interrupted", 130),
            "a run record with a signalled lane must be outcome interrupted / rc 130 (§G.1), \
             got {} / {}",
            out.outcome,
            out.rc
        );
        // The interrupt class wins over failure and deferral classes alike,
        // and over the refusal class when both are present (§G.1: "an
        // interrupted run exits 130 regardless of earlier failures").
        let failed = row("c", Failed, Some(1), "build-failed");
        let out = RunOutcome::compute(&[failed, signalled.clone()], true, false, false);
        assert_eq!((out.outcome, out.rc), ("interrupted", 130));
        let out = RunOutcome::compute(&[signalled], true, false, true);
        assert_eq!((out.outcome, out.rc), ("interrupted", 130));
    }
}
