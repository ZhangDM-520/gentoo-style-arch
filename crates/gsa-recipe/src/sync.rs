//! Version-sync providers and checksum anchoring (`gsa -Sy`;
//! `docs/gsa-contract.md` §B.4, `docs/build-guide.md` "Stable version sync and
//! checksum verification", `docs/MEMORY.md` rule 18).
//!
//! Providers: Arch official (`pacman -Si` + the official packaging repo's
//! `.SRCINFO` anchor) for untagged `packages/stable` recipes, and the
//! opted-in nvchecker path (`version-sync=nvchecker` topology tag;
//! `.nvchecker.toml` alone stays report-only) with AUR `.SRCINFO` and GitHub
//! release-digest sections. Rule 18: checksums anchor to the authority the
//! value came from — a provider that yields a new version must also anchor
//! the new source checksums from that same provider. A published-checksum
//! disagreement is an integrity stop that restores the recipe byte-for-byte;
//! a provider outage is a deferral (`anchoring-refused`,
//! `source-unfetchable`), never an invented version. Every rewrite is
//! transactional (snapshot → staged writes → one tmp+mv publish) and left
//! uncommitted in the working tree.
//!
//! Architecture of this module:
//!
//! * [`VersionProvider`] is the injection seam: the production handles
//!   ([`ArchOfficial`], [`AurProvider`], [`GithubProvider`]) shell out to
//!   `pacman`, `curl`, `nvchecker` and `git` through `PATH`, while tests
//!   supply in-process fakes that carry versions *and* published checksums.
//!   A checksum anchor can only ever come from the provider — never from the
//!   fetched bytes, which is what `updpkgsums` alone would happily accept.
//! * [`RecipeTransaction`] owns the snapshot/restore contract: the PKGBUILD
//!   bytes are snapshotted into a verified scratch directory *before the
//!   first write*, the pkgver+pkgrel+epoch rewrite lands on a staged copy and
//!   publishes as ONE tmp+mv, and every failure path restores byte-identical
//!   and reports [`RestoreStatus`] honestly (a failed restore is loud: the
//!   recipe "is left rewritten and must not be committed").
//! * [`sync_arch`] / [`sync_nvchecker`] are the two provider-family passes;
//!   each returns a [`SyncReport`] whose [`DispositionRow`]s the CLI renders
//!   with [`render_disposition`] as the run-level
//!   `Version and checksum sync this run (uncommitted — review with 'git
//!   diff', then commit):` block.
//!
//! The recipe's expanded `source=()` array is read the way `makepkg` reads it
//! — by sourcing the PKGBUILD in a `bash -c` child (the `pkgbuild_array_checked`
//! seam of the fish reference): tokenising the text gets `…{,.sig}` brace
//! pairs and `$pkgver` inside an entry wrong, and a mistake there silently
//! miscalculates checksum coverage. Evaluation failure is reported as
//! [`EvalError`], never masked as an empty array (the masking once let an
//! audit report a clean scan over recipes it never read, 2026-10-05).
//!
//! `--no-sync` is the caller's concern: the CLI simply never calls a pass.
//! When a pass is called, the caller has already established authorization —
//! for the nvchecker path that means the validated `version-sync=nvchecker`
//! topology tag; a `.nvchecker.toml` file alone NEVER authorizes a query or a
//! rewrite (`docs/MEMORY.md` rule 18, 2026-10-01).

use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

// ---------------------------------------------------------------------------
// Version values and the one charset gate
// ---------------------------------------------------------------------------

/// Which PKGBUILD version field a value is destined for; the gate differs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VersionField {
    Pkgver,
    Pkgrel,
    Epoch,
}

/// The one charset gate every `pkgver`/`pkgrel`/`epoch` value must pass before
/// it becomes rewrite text or a PKGBUILD line. These values arrive from
/// OUTSIDE the tree (`pacman -Si` Version text, AUR and nvchecker metadata)
/// and `&`, `\` and `/` corrupt a rewrite rather than fail it — one gate, both
/// sync paths, no second spelling of the rule (2026-10-05; the nvchecker path
/// gated this charset long before the Arch path did).
pub fn version_value_ok(field: VersionField, value: &str) -> bool {
    if value.is_empty() {
        return false;
    }
    match field {
        VersionField::Pkgver | VersionField::Pkgrel => value
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '+')),
        VersionField::Epoch => value.chars().all(|c| c.is_ascii_digit()),
    }
}

/// The three fields a repo/provider version resolves to. Kept as validated
/// strings: they are written verbatim into a PKGBUILD, never re-formatted
/// through a numeric type that would drop `1.0`'s trailing zero.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VersionFields {
    pub epoch: String,
    pub pkgver: String,
    pub pkgrel: String,
}

impl VersionFields {
    /// `epoch:pkgver-pkgrel`, with the epoch prefix only when non-zero —
    /// makepkg's `get_full_version` shape (2026-10-06).
    pub fn render(&self) -> String {
        let core = format!("{}-{}", self.pkgver, self.pkgrel);
        if self.epoch == "0" {
            core
        } else {
            format!("{}:{}", self.epoch, core)
        }
    }

    /// Parse a repository `Version` string (`2.42.2-1`, `7.2.4-1.1`,
    /// `1:7.1-1`) exactly as the fish reference splits it: epoch is the
    /// `^[0-9]+:` prefix; pkgver runs to the first `-<digit>`; pkgrel is the
    /// rest, defaulting to `1` when absent.
    pub fn parse(full: &str) -> Option<VersionFields> {
        let (epoch, rest) = match full.find(':') {
            Some(i) if i > 0 && full[..i].chars().all(|c| c.is_ascii_digit()) => {
                (full[..i].to_string(), &full[i + 1..])
            }
            _ => ("0".to_string(), full),
        };
        let bytes = rest.as_bytes();
        let mut split = None;
        for (i, b) in bytes.iter().enumerate() {
            if *b == b'-' && i + 1 < bytes.len() && bytes[i + 1].is_ascii_digit() {
                split = Some(i);
                break;
            }
        }
        let (pkgver, pkgrel) = match split {
            Some(i) => (rest[..i].to_string(), rest[i + 1..].to_string()),
            None => (rest.to_string(), "1".to_string()),
        };
        let pkgrel = if pkgrel.is_empty() {
            "1".to_string()
        } else {
            pkgrel
        };
        Some(VersionFields {
            epoch,
            pkgver,
            pkgrel,
        })
    }

    /// Every field must be writeable verbatim before a rewrite may start.
    pub fn validate(&self) -> bool {
        version_value_ok(VersionField::Pkgver, &self.pkgver)
            && version_value_ok(VersionField::Pkgrel, &self.pkgrel)
            && version_value_ok(VersionField::Epoch, &self.epoch)
    }
}

/// `vercmp` semantics: shell out to pacman-contrib's `vercmp` through `PATH`
/// and read its -1/0/1 answer; `None` means the tool is absent and callers
/// fall back to exact-string comparison (the fish reference's fallback).
pub fn vercmp(a: &str, b: &str) -> Option<i32> {
    let out = Command::new("vercmp").arg(a).arg(b).output().ok()?;
    if !out.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&out.stdout);
    text.trim().parse::<i32>().ok()
}

// ---------------------------------------------------------------------------
// Source entries
// ---------------------------------------------------------------------------

/// VCS transport of a `proto+url` source entry.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VcsProtocol {
    Git,
    Svn,
    Hg,
    Bzr,
}

/// One expanded `source=()` entry, exactly as `makepkg` sees it. The `name::`
/// override matters: `udisks2::git+…` downloads to `udisks2`, and reading the
/// URL basename instead made the verifier look for a file that does not exist
/// (and, for util-linux's renamed LICENSE, find a *different* file sharing
/// the name — a false mismatch in one direction and a false pass in the
/// other).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SourceEntry(pub String);

impl SourceEntry {
    /// Wrap one raw expanded entry.
    pub fn new(raw: impl Into<String>) -> SourceEntry {
        SourceEntry(raw.into())
    }

    /// The URL part with any `name::` override removed; `None` for an in-tree
    /// file (patch, dotfile, `.install`) that is not a download at all.
    pub fn url(&self) -> Option<&str> {
        let e = match self.0.find("::") {
            Some(i) => &self.0[i + 2..],
            None => &self.0,
        };
        if e.contains("://") {
            Some(e)
        } else {
            None
        }
    }

    /// The VCS protocol, read from the URL part: `fish::git+https://…` is a
    /// git checkout, and testing the raw entry would misclassify it as a
    /// tarball and then refuse the build.
    pub fn vcs(&self) -> Option<VcsProtocol> {
        let url = self.url()?;
        for (prefix, proto) in [
            ("git+", VcsProtocol::Git),
            ("svn+", VcsProtocol::Svn),
            ("hg+", VcsProtocol::Hg),
            ("bzr+", VcsProtocol::Bzr),
        ] {
            if url.starts_with(prefix) {
                return Some(proto);
            }
        }
        None
    }

    /// The name `makepkg` gives the entry — what a checksum array describes:
    /// the `name::` override when present, else the URL basename. `None` for
    /// a detached signature (`.sig`/`.asc`/`.signature`/`.sign` — makepkg
    /// writes `SKIP` for those; `.sign` is the kernel.org spelling that once
    /// made an official-SKIP entry look unanchorable and refused the recipe,
    /// 2026-09-24) and for an in-tree file.
    pub fn filename(&self) -> Option<String> {
        let name = if let Some(i) = self.0.find("::") {
            self.0[..i].to_string()
        } else {
            url_basename(self.url()?)?
        };
        if name.is_empty() {
            return None;
        }
        for suffix in [".sig", ".asc", ".signature", ".sign"] {
            if name.ends_with(suffix) {
                return None;
            }
        }
        Some(name)
    }

    /// The REMOTE basename of the URL — the GitHub release-asset binding key.
    /// For a `name::url` source the asset is selected by this name while
    /// `name` still identifies the local fetched file.
    pub fn remote_basename(&self) -> Option<String> {
        url_basename(self.url()?)
    }

    /// The pinned VCS ref of a `#tag=`/`#commit=` fragment, with makepkg's
    /// `?signed` verification suffix stripped (the ref name itself must never
    /// carry it, or `git archive` looks up a ref that cannot exist and the
    /// anchor reports a false checksum mismatch: systemd, 2026-10-02).
    pub fn vcs_ref(&self) -> Option<(String, String)> {
        let url = self.url()?;
        let frag = url.split_once('#')?.1;
        let frag = frag.strip_suffix("?signed").unwrap_or(frag);
        let (kind, value) = frag.split_once('=')?;
        match kind {
            "tag" | "commit" => Some((kind.to_string(), value.to_string())),
            _ => None,
        }
    }
}

fn url_basename(url: &str) -> Option<String> {
    let stripped = match url.find(['?', '#']) {
        Some(i) => &url[..i],
        None => url,
    };
    // makepkg strips trailing slashes before deriving the checkout name (the
    // `url=`-ending-in-`/` libyuv shape left an empty basename and the VCS
    // recorder refused a green build with 'missing local checkout').
    let stripped = stripped.trim_end_matches('/');
    let name = stripped.rsplit('/').next().unwrap_or("");
    if name.is_empty() {
        None
    } else {
        Some(name.to_string())
    }
}

// ---------------------------------------------------------------------------
// Isolated recipe evaluation (bash through PATH)
// ---------------------------------------------------------------------------

/// How an isolated recipe evaluation failed. Evaluation failure is a named
/// outcome, never an empty array (2026-10-05).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum EvalError {
    /// `bash` is not on PATH — nothing can be evaluated.
    ToolMissing,
    /// The recipe could not be sourced (`bash -c` rc 2).
    NotSourcable,
    /// The requested name is not a valid shell identifier.
    InvalidName,
}

impl std::fmt::Display for EvalError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            EvalError::ToolMissing => write!(f, "bash is not available on PATH"),
            EvalError::NotSourcable => write!(f, "the PKGBUILD could not be sourced"),
            EvalError::InvalidName => write!(f, "invalid variable/array name"),
        }
    }
}

/// `pkgbuild_var` semantics: the evaluated value of one PKGBUILD scalar (an
/// unset variable is the empty string). Positional arguments only — a recipe
/// path may carry a quote the interpolated form would break or inject
/// through (2026-10-05).
pub fn pkgbuild_var(recipe_dir: &Path, var: &str) -> Result<String, EvalError> {
    if !valid_name(var) {
        return Err(EvalError::InvalidName);
    }
    let out = bash_eval(PKG_BUILD_VAR_SCRIPT, &[recipe_dir, Path::new(var)])?;
    match out.status.code() {
        Some(0) => Ok(String::from_utf8_lossy(&out.stdout)
            .lines()
            .next()
            .unwrap_or("")
            .to_string()),
        _ => Err(EvalError::NotSourcable),
    }
}

/// `pkgbuild_array_checked` semantics: an expanded PKGBUILD array, one element
/// per line. Sourcing is the only way to get what `makepkg` sees —
/// `source=(…tar.gz{,.sig})` is two entries and `{,-doc}` is two more, and a
/// `$pkgver` inside an entry is a version. rc 0 with zero rows is a genuinely
/// empty array; a sourcing failure is [`EvalError::NotSourcable`], never
/// silently "no sources".
pub fn pkgbuild_array_checked(recipe_dir: &Path, name: &str) -> Result<Vec<String>, EvalError> {
    if !valid_name(name) {
        return Err(EvalError::InvalidName);
    }
    let out = bash_eval(PKG_BUILD_ARRAY_SCRIPT, &[recipe_dir, Path::new(name)])?;
    match out.status.code() {
        Some(0) => Ok(String::from_utf8_lossy(&out.stdout)
            .lines()
            .map(|l| l.to_string())
            .collect()),
        _ => Err(EvalError::NotSourcable),
    }
}

fn valid_name(name: &str) -> bool {
    let mut chars = name.chars();
    match chars.next() {
        Some(c) if c.is_ascii_alphabetic() || c == '_' => {}
        _ => return false,
    }
    chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

fn bash_eval(script: &str, args: &[&Path]) -> Result<std::process::Output, EvalError> {
    // Build-domain command: `script` evaluates recipe code (arbitrary shell
    // from the PKGBUILD), so under a privileged run it is dropped to the
    // build user — a recipe never executes as root.
    let mut cmd = gsa_model::privilege::build_command("bash");
    cmd.arg("-c").arg(script).arg("_");
    for a in args {
        cmd.arg(a);
    }
    cmd.output().map_err(|_| EvalError::ToolMissing)
}

const PKG_BUILD_VAR_SCRIPT: &str = r#"
[[ $2 =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || exit 2
__gsa_pkgbuild_var_name=$2
readonly __gsa_pkgbuild_var_name
cd "$1" || exit 1
source ./PKGBUILD >/dev/null 2>&1 || exit $?
declare -p "$__gsa_pkgbuild_var_name" >/dev/null 2>&1 || exit 0
printf "%s\n" "${!__gsa_pkgbuild_var_name}"
"#;

const PKG_BUILD_ARRAY_SCRIPT: &str = r#"
[[ $2 =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || exit 2
__gsa_arr_name=$2
cd "$1" || exit 2
source ./PKGBUILD >/dev/null 2>&1 || exit 2
declare -p "$__gsa_arr_name" >/dev/null 2>&1 || exit 0
eval "set -- \"\${$__gsa_arr_name[@]}\""
(( $# )) || exit 0
printf "%s\n" "$@"
"#;

/// Plan the bump of a COMPUTED `pkgver` (`pkgver=${_major}.${_rcver}`): one
/// `var=newvalue` row per variable assignment that must move for the
/// expression to evaluate to TARGET, chosen by keeping the most variables
/// unchanged and then the smallest total edit distance to their current
/// values (a plain rc bump moves only `_rcver`). The expression itself is
/// never rewritten — clobbering it with a literal silently pins the version
/// and defeats the variable tracking (the `pkgver()`-override hazard in
/// reverse). Ported verbatim from the fish reference's bash planner; the
/// tokenizer refuses anything beyond `$var`/`${var}` rather than guessing.
/// Exit: 0 planned · 2 unsupported expression · 3 unrewritable variable ·
/// 4 target not expressible through the expression.
const PKG_BUILD_PLAN_SCRIPT: &str = r##"
pkg_path=$1
target=$2
rhs=""
while IFS= read -r line; do
    case "$line" in
        pkgver=*) rhs=${line#pkgver=}; break ;;
    esac
done <"$pkg_path/PKGBUILD"
[[ -n $rhs ]] || exit 2
case "$rhs" in
    \"*\") rhs=${rhs#\"}; rhs=${rhs%\"} ;;
esac

segs=()
seg_vars=()
lit=""
i=0
len=${#rhs}
while ((i < len)); do
    ch=${rhs:i:1}
    if [[ $ch == "$" ]]; then
        j=$((i + 1))
        if ((j < len)) && [[ ${rhs:j:1} == "{" ]]; then
            j=$((j + 1))
            name=""
            while ((j < len)) && [[ ${rhs:j:1} == [A-Za-z0-9_] ]]; do
                name+=${rhs:j:1}
                j=$((j + 1))
            done
            if [[ -z $name || ${rhs:j:1} != "}" ]]; then exit 2; fi
            end=$((j + 1))
        else
            name=""
            while ((j < len)) && [[ ${rhs:j:1} == [A-Za-z0-9_] ]]; do
                name+=${rhs:j:1}
                j=$((j + 1))
            done
            [[ -n $name ]] || exit 2
            end=$j
        fi
        [[ $name == [A-Za-z_]* ]] || exit 2
        case "$name" in pkgver | pkgrel | epoch) exit 2 ;; esac
        if [[ -n $lit ]]; then segs+=("L$lit"); lit=""; fi
        segs+=("V$name")
        seg_vars+=("$name")
        i=$end
    elif [[ $ch == "\`" ]]; then
        exit 2
    else
        lit+=$ch
        i=$((i + 1))
    fi
done
[[ -n $lit ]] && segs+=("L$lit")
has_var=0
for s in "${segs[@]}"; do [[ $s == V* ]] && has_var=1; done
((has_var)) || exit 2

cd "$pkg_path" || exit 2
source ./PKGBUILD >/dev/null 2>&1 || exit 2
declare -A cur=()
var_order=()
for name in "${seg_vars[@]}"; do
    [[ -z ${cur[$name]+x} ]] || continue
    var_order+=("$name")
    eval "cur[\$name]=\${$name-}"
    [[ $(grep -c "^$name=" PKGBUILD) == 1 ]] || exit 3
    assign=$(grep -m1 "^$name=" PKGBUILD)
    val=${assign#*=}
    case "$val" in
        \"*\") val=${val#\"}; val=${val%\"} ;;
    esac
    [[ $val =~ ^[A-Za-z0-9._+-]*$ ]] || exit 3
done

sep=$(printf "\037")
declare -a sols=()
solve() {
    local idx=$1 pos=$2 prefix=$3
    local tlen=${#target}
    if ((idx == ${#segs[@]})); then
        ((pos == tlen)) && sols+=("$prefix")
        return 0
    fi
    local seg=${segs[idx]}
    if [[ $seg == L* ]]; then
        local text=${seg#L}
        [[ ${target:pos:${#text}} == "$text" ]] || return 0
        solve $((idx + 1)) $((pos + ${#text})) "$prefix"
        return 0
    fi
    local nextlit=""
    if ((idx + 1 < ${#segs[@]})) && [[ ${segs[idx+1]} == L* ]]; then
        nextlit=${segs[idx+1]#L}
    fi
    if [[ -z $nextlit ]]; then
        if ((idx + 1 == ${#segs[@]})); then
            ((pos < tlen)) || return 0
            solve $((idx + 1)) $tlen "$prefix$sep${target:pos}"
        else
            local k
            for ((k = pos + 1; k <= tlen; k++)); do
                solve $((idx + 1)) $k "$prefix$sep${target:pos:k-pos}"
            done
        fi
        return 0
    fi
    local nl=${#nextlit} o
    for ((o = 1; pos + o + nl <= tlen; o++)); do
        [[ ${target:pos+o:nl} == "$nextlit" ]] || continue
        solve $((idx + 1)) $((pos + o)) "$prefix$sep${target:pos:o}"
    done
}
solve 0 0 ""
((${#sols[@]})) || exit 4

lev() {
    local a=$1 b=$2 i j
    local -a prev currow
    for ((j = 0; j <= ${#b}; j++)); do prev[j]=$j; done
    for ((i = 1; i <= ${#a}; i++)); do
        currow[0]=$i
        for ((j = 1; j <= ${#b}; j++)); do
            local cost=1
            [[ ${a:i-1:1} == "${b:j-1:1}" ]] && cost=0
            local m=$((prev[j] + 1))
            ((currow[j-1] + 1 < m)) && m=$((currow[j-1] + 1))
            ((prev[j] + cost < m)) && m=$((prev[j] + cost))
            currow[j]=$m
        done
        for ((j = 0; j <= ${#b}; j++)); do prev[j]=${currow[j]}; done
    done
    printf "%s\n" "${prev[${#b}]}"
}

declare -A best=()
have_best=0
best_unchanged=-1
best_dist=1000000
for sol in "${sols[@]}"; do
    body=${sol#"$sep"}
    IFS=$sep read -r -a vals <<<"$body"
    ((${#vals[@]} == ${#seg_vars[@]})) || continue
    declare -A newval=()
    ok=1
    for ((k = 0; k < ${#seg_vars[@]}; k++)); do
        name=${seg_vars[k]}
        v=${vals[k]}
        if [[ -n ${newval[$name]+x} && ${newval[$name]} != "$v" ]]; then ok=0; break; fi
        newval[$name]=$v
    done
    ((ok)) || continue
    unchanged=0
    dist=0
    for name in "${var_order[@]}"; do
        if [[ ${cur[$name]} == "${newval[$name]}" ]]; then
            unchanged=$((unchanged + 1))
        else
            d=$(lev "${cur[$name]}" "${newval[$name]}")
            dist=$((dist + d))
        fi
    done
    if ((unchanged > best_unchanged)) || { ((unchanged == best_unchanged)) && ((dist < best_dist)); }; then
        have_best=1
        best_unchanged=$unchanged
        best_dist=$dist
        best=()
        for name in "${var_order[@]}"; do best[$name]=${newval[$name]}; done
    fi
done
((have_best)) || exit 4

for name in "${var_order[@]}"; do
    [[ ${cur[$name]} == "${best[$name]}" ]] && continue
    printf "%s=%s\n" "$name" "${best[$name]}"
done
exit 0
"##;

/// Raw text of the first top-level `pkgver=` assignment, unevaluated. `None`
/// when the recipe has no such line (a `pkgver()` function, which the sync
/// paths skip — inserting a literal would OVERRIDE `pkgver()` and pin the
/// version, defeating dev-branch tracking).
pub fn pkgbuild_pkgver_rhs(recipe_dir: &Path) -> Option<String> {
    let text = fs::read_to_string(recipe_dir.join("PKGBUILD")).ok()?;
    for line in text.lines() {
        if let Some(rhs) = line.strip_prefix("pkgver=") {
            return Some(rhs.to_string());
        }
    }
    None
}

// ---------------------------------------------------------------------------
// Scratch space and the recipe transaction
// ---------------------------------------------------------------------------

/// A structural failure of the sync machinery itself (scratch, snapshot,
/// staged publish). Policy refusals are typed outcomes, not errors.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SyncError {
    /// What structurally failed.
    pub message: String,
}

impl std::fmt::Display for SyncError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl std::error::Error for SyncError {}

fn sync_err(message: impl Into<String>) -> SyncError {
    SyncError {
        message: message.into(),
    }
}

/// A verified scratch directory outside the repository. Deriving paths from
/// an UNCHECKED temp dir collapses them to the filesystem root on failure
/// ("/PKGBUILD.orig"), where a root-mode failure path would "restore" from
/// `/PKGBUILD.orig` (2026-10-05). Every path a transaction uses derives only
/// from the directory this returns, and a `$TMPDIR` inside the repository is
/// refused outright — scratch must never be committed by accident.
pub struct ScratchDir {
    path: PathBuf,
}

impl ScratchDir {
    /// Create `gsa-<label>.<unique>` under `$TMPDIR` (or the system temp
    /// dir), refusing a base that resolves inside `repo_root`.
    pub fn new(label: &str, repo_root: &Path) -> Result<ScratchDir, SyncError> {
        let repo = fs::canonicalize(repo_root)
            .map_err(|_| sync_err("cannot resolve the repository root"))?;
        let base = match std::env::var_os("TMPDIR") {
            Some(v) if !v.is_empty() => PathBuf::from(v),
            _ => std::env::temp_dir(),
        };
        let base = fs::canonicalize(&base)
            .map_err(|_| sync_err("cannot resolve a safe temporary directory"))?;
        if base == repo || base.starts_with(&repo) {
            return Err(sync_err("TMPDIR must be outside the repository"));
        }
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let dir = base.join(format!("gsa-{}.{}.{}", label, std::process::id(), nanos));
        fs::create_dir(&dir)
            .map_err(|_| sync_err("cannot create an isolated temporary directory"))?;
        let resolved = match fs::canonicalize(&dir) {
            Ok(p) => p,
            Err(_) => {
                let _ = fs::remove_dir_all(&dir);
                return Err(sync_err("cannot resolve the isolated temporary directory"));
            }
        };
        Ok(ScratchDir { path: resolved })
    }

    /// The verified scratch root.
    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for ScratchDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

/// What a restore attempt actually achieved — never a claim. A recipe left
/// rewritten after a failed restore is exactly what the owner must be told
/// about ("left rewritten and must not be committed", 2026-10-05).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RestoreStatus {
    /// The snapshot was republished over the recipe byte-identically.
    Restored,
    /// Nothing had reached the tracked file yet, so there was nothing to
    /// restore — the recipe still holds its pre-pass bytes.
    NothingToRestore,
    /// The restore FAILED; the recipe is left rewritten and must not be
    /// committed.
    Failed(String),
}

impl RestoreStatus {
    /// Did the recipe end up in its pre-pass state?
    pub fn ok(&self) -> bool {
        matches!(
            self,
            RestoreStatus::Restored | RestoreStatus::NothingToRestore
        )
    }
}

/// The staged filename of a rewrite. Fixed per process so a test can predict
/// it (and pre-create it to force a publish failure); the per-process name
/// cannot collide with a concurrent run's (2026-10-05).
pub fn staged_name() -> String {
    format!("PKGBUILD.tmp.{}", std::process::id())
}

/// Owns the snapshot → staged write → one tmp+mv publish → restore lifecycle
/// of one recipe rewrite. The snapshot is taken BEFORE the first write; every
/// failure path of every pass funnels through [`RecipeTransaction::restore`],
/// which publishes the snapshot through its own tmp+mv (a reader never sees a
/// half-copied recipe). The tracked PKGBUILD is never edited in place — the
/// one exception is `updpkgsums`, an external in-place writer the anchor step
/// guards with this same snapshot.
pub struct RecipeTransaction {
    recipe_dir: PathBuf,
    _scratch: ScratchDir,
    snapshot: PathBuf,
    staged: PathBuf,
    dirty: bool,
}

impl RecipeTransaction {
    /// Snapshot `<recipe_dir>/PKGBUILD` into verified scratch outside the
    /// repository. Fails closed: without a rollback-safe snapshot the version
    /// sync must not start at all.
    pub fn begin(recipe_dir: &Path, repo_root: &Path) -> Result<RecipeTransaction, SyncError> {
        let scratch = ScratchDir::new("version-sync", repo_root)?;
        let snapshot = scratch.path().join("PKGBUILD.original");
        if fs::copy(recipe_dir.join("PKGBUILD"), &snapshot).is_err() {
            return Err(sync_err("cannot snapshot PKGBUILD before the version sync"));
        }
        let staged = recipe_dir.join(staged_name());
        Ok(RecipeTransaction {
            recipe_dir: recipe_dir.to_path_buf(),
            _scratch: scratch,
            snapshot,
            staged,
            dirty: false,
        })
    }

    /// The staged copy every field rewrite writes to (permissions preserved).
    pub fn stage(&self) -> Result<PathBuf, SyncError> {
        fs::copy(self.recipe_dir.join("PKGBUILD"), &self.staged)
            .map_err(|_| sync_err("could not stage the version rewrite"))?;
        Ok(self.staged.clone())
    }

    /// Publish the whole pkgver+pkgrel+epoch rewrite as ONE tmp+mv, so no
    /// reader and no second run can observe the recipe between two of its own
    /// fields.
    pub fn publish(&mut self) -> Result<(), SyncError> {
        fs::rename(&self.staged, self.recipe_dir.join("PKGBUILD"))
            .map_err(|_| sync_err("could not publish the version rewrite"))?;
        gsa_model::privilege::own_to_build_user(&self.recipe_dir.join("PKGBUILD"))
            .map_err(|e| sync_err(format!("could not hand the published recipe back to the build user: {e}")))?;
        self.dirty = true;
        Ok(())
    }

    /// An external step (`updpkgsums`) rewrote the tracked file in place; the
    /// snapshot must now guard it.
    pub fn mark_dirty(&mut self) {
        self.dirty = true;
    }

    /// Drop an unpublished staged copy on an abort.
    pub fn discard_staged(&self) {
        let _ = fs::remove_file(&self.staged);
    }

    /// Restore the pre-pass bytes: copy the snapshot to a fresh staged name
    /// and rename it over the recipe. The status is measured, not claimed.
    pub fn restore(&mut self) -> RestoreStatus {
        if !self.dirty {
            self.discard_staged();
            return RestoreStatus::NothingToRestore;
        }
        let work = self.recipe_dir.join(format!("{}.restore", staged_name()));
        if let Err(e) = fs::copy(&self.snapshot, &work) {
            self.discard_staged();
            return RestoreStatus::Failed(format!("could not copy the snapshot back: {e}"));
        }
        if let Err(e) = fs::rename(&work, self.recipe_dir.join("PKGBUILD")) {
            let _ = fs::remove_file(&work);
            return RestoreStatus::Failed(format!("could not republish the snapshot: {e}"));
        }
        if let Err(e) = gsa_model::privilege::own_to_build_user(&self.recipe_dir.join("PKGBUILD")) {
            return RestoreStatus::Failed(format!("restored the recipe but could not hand it back to the build user: {e}"));
        }
        self.dirty = false;
        RestoreStatus::Restored
    }

    /// Success path: leave the rewritten recipe in the working tree,
    /// UNCOMMITTED — a run never commits; that disposition stays the
    /// maintainer's.
    pub fn keep(self) {}
}

/// Why a pkgver rewrite could not be applied — the named refusal classes of
/// the fish reference (rc 3/4/5 there), preserved as types instead of being
/// collapsed into one code.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PkgverPlanError {
    /// The value itself cannot be written verbatim (`&`, `\`, `/`, whitespace).
    UnsafeValue,
    /// `pkgver` is computed by an expression this sync cannot rewrite (only
    /// literal-and-`${var}` constructions are); bump its variables by hand.
    UnsupportedExpression,
    /// Upstream version cannot be expressed through the recipe's pkgver
    /// expression; the recipe keeps its current version.
    Inexpressible,
    /// A referenced variable has no single plain-literal assignment line to
    /// rewrite; bump it by hand.
    UnrewritableVariable,
    /// The write itself failed; the caller owns restore semantics.
    WriteFailed,
}

impl std::fmt::Display for PkgverPlanError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PkgverPlanError::UnsafeValue => {
                write!(f, "unsupported version format for a safe rewrite")
            }
            PkgverPlanError::UnsupportedExpression => write!(
                f,
                "pkgver is computed by an expression this version sync cannot rewrite (only literal-and-${{var}} constructions are); bump its variables by hand"
            ),
            PkgverPlanError::Inexpressible => write!(
                f,
                "upstream version cannot be expressed through this recipe's pkgver expression; the recipe keeps its current version"
            ),
            PkgverPlanError::UnrewritableVariable => write!(
                f,
                "a pkgver variable has no single plain-literal assignment line to rewrite; bump it by hand"
            ),
            PkgverPlanError::WriteFailed => write!(f, "the staged write failed"),
        }
    }
}

/// Rewrite `pkgver` on the caller's STAGED copy. A literal `pkgver=` line is
/// rewritten as it always was; a COMPUTED `pkgver=${var}…` expression is
/// never clobbered with a literal — its variables are bumped instead so it
/// evaluates to `new_pkgver`.
pub fn apply_pkgver_version(
    staged: &Path,
    recipe_dir: &Path,
    new_pkgver: &str,
) -> Result<(), PkgverPlanError> {
    if !version_value_ok(VersionField::Pkgver, new_pkgver) {
        return Err(PkgverPlanError::UnsafeValue);
    }
    let text = fs::read_to_string(staged).map_err(|_| PkgverPlanError::WriteFailed)?;
    let rhs = match text.lines().find_map(|l| l.strip_prefix("pkgver=")) {
        Some(r) => r.to_string(),
        None => return Err(PkgverPlanError::UnsupportedExpression),
    };
    // Computed iff bash would expand it: anything outside a single-quoted RHS
    // that carries `$` or a command substitution.
    let quoted = rhs.len() >= 2 && rhs.starts_with('\'') && rhs.ends_with('\'');
    let computed = !quoted && (rhs.contains('$') || rhs.contains('`'));

    if !computed {
        let rewritten = rewrite_lines(&text, "pkgver=", &format!("pkgver={new_pkgver}"));
        write_atomic(staged, &rewritten).map_err(|_| PkgverPlanError::WriteFailed)?;
        return Ok(());
    }

    // Computed: touch nothing unless the version must actually move.
    let cur =
        pkgbuild_var(recipe_dir, "pkgver").map_err(|_| PkgverPlanError::UnsupportedExpression)?;
    if cur == new_pkgver {
        return Ok(());
    }
    let plan = pkgbuild_pkgver_plan(recipe_dir, new_pkgver)?;
    for row in plan {
        let Some((name, value)) = row.split_once('=') else {
            return Err(PkgverPlanError::UnsupportedExpression);
        };
        if !valid_name(name) {
            return Err(PkgverPlanError::UnsupportedExpression);
        }
        if !version_value_ok(VersionField::Pkgver, value) {
            return Err(PkgverPlanError::UnsupportedExpression);
        }
        let current = fs::read_to_string(staged).map_err(|_| PkgverPlanError::WriteFailed)?;
        let rewritten = rewrite_lines(&current, &format!("{name}="), &format!("{name}={value}"));
        write_atomic(staged, &rewritten).map_err(|_| PkgverPlanError::WriteFailed)?;
    }
    Ok(())
}

/// Plan a computed-pkgver bump: `var=value` rows only. Exit mapping mirrors
/// the bash planner.
fn pkgbuild_pkgver_plan(recipe_dir: &Path, target: &str) -> Result<Vec<String>, PkgverPlanError> {
    let out = bash_eval(PKG_BUILD_PLAN_SCRIPT, &[recipe_dir, Path::new(target)])
        .map_err(|_| PkgverPlanError::WriteFailed)?;
    match out.status.code() {
        Some(0) => Ok(String::from_utf8_lossy(&out.stdout)
            .lines()
            .map(|l| l.to_string())
            .collect()),
        Some(3) => Err(PkgverPlanError::UnrewritableVariable),
        Some(4) => Err(PkgverPlanError::Inexpressible),
        _ => Err(PkgverPlanError::UnsupportedExpression),
    }
}

/// The pkgrel/epoch half of a version rewrite, applied to the caller's staged
/// PKGBUILD. `pkgrel` is always rewritten; `epoch` is rewritten when present
/// and inserted after the `pkgrel` line only when non-zero (never inside
/// `pkgver` — makepkg rejects colons there).
pub fn apply_release_metadata(
    staged: &Path,
    pkgrel: &str,
    epoch: &str,
) -> Result<(), PkgverPlanError> {
    if !version_value_ok(VersionField::Pkgrel, pkgrel)
        || !version_value_ok(VersionField::Epoch, epoch)
    {
        return Err(PkgverPlanError::UnsafeValue);
    }
    let text = fs::read_to_string(staged).map_err(|_| PkgverPlanError::WriteFailed)?;
    let has_epoch = text.lines().any(|l| l.starts_with("epoch="));
    let mut out: Vec<String> = Vec::new();
    for line in text.lines() {
        if line.starts_with("pkgrel=") {
            out.push(format!("pkgrel={pkgrel}"));
            if !has_epoch && epoch != "0" {
                out.push(format!("epoch={epoch}"));
            }
        } else if has_epoch && line.starts_with("epoch=") {
            out.push(format!("epoch={epoch}"));
        } else {
            out.push(line.to_string());
        }
    }
    let joined = join_lines(&out, text.ends_with('\n'));
    write_atomic(staged, &joined).map_err(|_| PkgverPlanError::WriteFailed)
}

fn rewrite_lines(text: &str, prefix: &str, replacement: &str) -> String {
    let out: Vec<String> = text
        .lines()
        .map(|l| {
            if l.starts_with(prefix) {
                replacement.to_string()
            } else {
                l.to_string()
            }
        })
        .collect();
    join_lines(&out, text.ends_with('\n'))
}

fn join_lines(lines: &[String], trailing_newline: bool) -> String {
    let mut s = lines.join("\n");
    if trailing_newline {
        s.push('\n');
    }
    s
}

fn write_atomic(path: &Path, content: &str) -> std::io::Result<()> {
    let mut f = fs::File::create(path)?;
    f.write_all(content.as_bytes())?;
    f.sync_all().ok();
    Ok(())
}

// ---------------------------------------------------------------------------
// Committed .SRCINFO refresh
// ---------------------------------------------------------------------------

/// What refreshing the committed `.SRCINFO` achieved. A failure is surfaced
/// twice on purpose: a named line carrying the regeneration command and the
/// run-level witness — the stale committed `.SRCINFO` stays the truth later
/// gates read until the owner regenerates it (2026-10-05).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SrcinfoRefresh {
    /// Regenerated and republished (or never needed).
    Refreshed,
    /// No committed `.SRCINFO` to refresh (nothing to do).
    NonePresent,
    /// `makepkg --printsrcinfo` failed.
    MakepkgFailed(String),
    /// The refreshed file could not replace the committed one.
    PublishFailed(String),
}

impl SrcinfoRefresh {
    /// Did the refresh leave the committed `.SRCINFO` stale?
    pub fn failed(&self) -> bool {
        !matches!(
            self,
            SrcinfoRefresh::Refreshed | SrcinfoRefresh::NonePresent
        )
    }

    /// The witness suffix the fish sync line carries on failure — the gap
    /// rides the same line, where the run summary cannot bury it.
    pub fn witness_suffix(&self) -> &'static str {
        match self {
            SrcinfoRefresh::Refreshed | SrcinfoRefresh::NonePresent => "",
            _ => " — the committed .SRCINFO could NOT be refreshed; regenerate it with 'makepkg --printsrcinfo' before committing",
        }
    }
}

/// Regenerate the committed `.SRCINFO` through `makepkg` (PATH) and publish it
/// atomically. `updpkgsums` and this step run as the build user even in root
/// mode — `makepkg` refuses to run as root; `gsa-model::priv` drops the spawn
/// and hands the published file back to the build user.
pub fn refresh_package_srcinfo(recipe_dir: &Path) -> SrcinfoRefresh {
    let committed = recipe_dir.join(".SRCINFO");
    if !committed.is_file() {
        return SrcinfoRefresh::NonePresent;
    }
    let out = match gsa_model::privilege::build_command("makepkg")
        .arg("--printsrcinfo")
        .arg("--dir")
        .arg(recipe_dir)
        .output()
    {
        Ok(o) => o,
        Err(e) => return SrcinfoRefresh::MakepkgFailed(format!("{e}")),
    };
    if !out.status.success() {
        return SrcinfoRefresh::MakepkgFailed(format!(
            "makepkg --printsrcinfo exited {}",
            out.status
        ));
    }
    let tmp = recipe_dir.join(format!(".SRCINFO.tmp.{}", std::process::id()));
    if fs::write(&tmp, &out.stdout).is_err() {
        return SrcinfoRefresh::PublishFailed("could not stage the refreshed .SRCINFO".into());
    }
    if fs::rename(&tmp, &committed).is_err() {
        let _ = fs::remove_file(&tmp);
        return SrcinfoRefresh::PublishFailed("could not replace the committed .SRCINFO".into());
    }
    if let Err(e) = gsa_model::privilege::own_to_build_user(&committed) {
        return SrcinfoRefresh::PublishFailed(format!(
            "refreshed the .SRCINFO but could not hand it back to the build user: {e}"
        ));
    }
    SrcinfoRefresh::Refreshed
}

// ---------------------------------------------------------------------------
// Provider seam
// ---------------------------------------------------------------------------

/// A provider failure. The pass maps these: outages and metadata races DEFER
/// (restore, retry later, never invent a version); unsupported mappings
/// refuse.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ProviderError {
    /// Network/tool outage or an AUR metadata race — retryable.
    Outage(String),
    /// The provider cannot express this recipe's version mapping.
    Unsupported(String),
    /// Metadata exists but disagrees or cannot be parsed.
    Invalid(String),
    /// A required PATH tool is missing.
    ToolMissing(String),
}

impl std::fmt::Display for ProviderError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ProviderError::Outage(m) => write!(f, "provider outage: {m}"),
            ProviderError::Unsupported(m) => write!(f, "unsupported mapping: {m}"),
            ProviderError::Invalid(m) => write!(f, "invalid metadata: {m}"),
            ProviderError::ToolMissing(m) => write!(f, "missing tool: {m}"),
        }
    }
}

/// The three answers a candidate-name query can give. "The name is unknown"
/// (pacman's not-found answer) and "the QUERY failed" (unsynced db, broken
/// mirror) are different claims: the first leaves nothing to sync to, the
/// second leaves the committed version's freshness UNVERIFIED and must never
/// fold into the first — that silent fold is what let a stale version build
/// with no log and no note (2026-10-05).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum VersionAnswer {
    /// A full epoch/pkgver/pkgrel answer.
    Found(VersionFields),
    /// The name is not in the repos at all.
    UnknownName,
    /// The query itself failed.
    QueryFailed(String),
}

/// Provider-supplied release metadata (pkgrel/epoch) for a resolved pkgver.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReleaseMetadata {
    /// The upstream/local pkgrel to adopt under the family's policy.
    pub pkgrel: String,
    /// The epoch to adopt under the family's policy.
    pub epoch: String,
}

/// A provider-published checksum: the only values a refreshed sum may be
/// anchored to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PublishedSum {
    /// `sha256`/`sha512`/`md5`/`b2`.
    pub algorithm: String,
    /// The published digest (lowercase hex).
    pub value: String,
}

/// The published checksums of one provider revision, keyed by the provider's
/// own binding (Arch/AUR: the name `makepkg` gives the source; GitHub: the
/// release-asset remote basename). `extras` are provider-only sources —
/// reported in the log, never anchored (2026-10-07 gcc-snapshot: AUR carries
/// `gcc-ada-repro.patch` for the ada frontend that recipe trims; byte
/// equality refused a checksum anchor that was correct for every source the
/// recipe does build).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PublishedSums {
    /// Binding key → published digest.
    pub entries: BTreeMap<String, PublishedSum>,
    /// Provider-only sources (never anchored).
    pub extras: Vec<String>,
    /// The identity whose revision carries these sums ("bash", an AUR
    /// pkgbase, a GitHub repo) — the anchor label names it.
    pub published_id: String,
}

/// One-way source coverage: every recipe source must appear VERBATIM in the
/// provider's list; a provider superset is valid (its extras are reported),
/// a recipe superset refuses the anchor (2026-10-09 gcc-snapshot: local fixes
/// on an anchored recipe live inside `prepare()`, never in `source=()`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Coverage {
    /// The provider covers every recipe source; extras are provider-only.
    Covered {
        /// Provider-only source entries.
        extras: Vec<String>,
    },
    /// The recipe ships sources the provider does not publish.
    NotCovered {
        /// Recipe sources missing from the provider list.
        missing: Vec<String>,
    },
}

/// Provider family — drives the release-metadata policy of the nvchecker
/// path (GitHub resets `pkgrel` to 1 only when `pkgver` moves; AUR takes
/// `pkgrel`/`epoch` from its `.SRCINFO`; anything else keeps the local
/// revision).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProviderFamily {
    /// The Arch official repos.
    Arch,
    /// The AUR.
    Aur,
    /// GitHub releases.
    Github,
    /// Any other nvchecker source.
    Other,
}

/// The injection seam tests replace with fakes and production fills with
/// PATH-shelling handles. Everything a checksum anchor needs — the published
/// values AND the binding from source entry to map key — comes through this
/// trait, so a substituted download can never become the anchor.
pub trait VersionProvider {
    /// Disposition-row label: "Arch repo", "AUR <id>", "GitHub <owner/repo>".
    fn label(&self) -> String;

    /// The authority phrase of anchor messages ("the official", "AUR",
    /// "GitHub").
    fn anchor_owner_label(&self) -> String {
        match self.family() {
            ProviderFamily::Arch => "the official".to_string(),
            ProviderFamily::Aur => "AUR".to_string(),
            ProviderFamily::Github => "GitHub".to_string(),
            ProviderFamily::Other => "the provider".to_string(),
        }
    }

    /// Which release-metadata policy applies in the nvchecker path.
    fn family(&self) -> ProviderFamily;

    /// PATH tools this provider shells out to. The anchoring step refuses to
    /// start (defer) when one is missing — the `curl`/`updpkgsums` gates of
    /// the fish reference; an in-process fake needs none.
    fn required_tools(&self) -> Vec<&'static str> {
        Vec::new()
    }

    /// Resolve one candidate name (pkgbase first, then every split pkgname —
    /// `hip-runtime` builds `hip-runtime-amd`, so a pkgbase-only query would
    /// silently never sync).
    fn query_name(&self, name: &str) -> Result<VersionAnswer, ProviderError>;

    /// Provider release metadata (pkgrel/epoch) for the resolved pkgver.
    fn release_metadata(
        &self,
        info: &RecipeInfo,
        pkgver: &str,
    ) -> Result<ReleaseMetadata, ProviderError>;

    /// The published checksums at the just-synced version. `Err(Outage)` is a
    /// deferral; a revision that does not carry our version is `Err(Invalid)`
    /// (anchoring to another version's checksums would describe different
    /// files) and defers as `anchoring-refused`.
    fn published_sums(
        &self,
        info: &RecipeInfo,
        version: &VersionFields,
    ) -> Result<PublishedSums, ProviderError>;

    /// The key one source entry binds to in [`VersionProvider::published_sums`],
    /// or `None` when the entry cannot bind (it then follows the loud
    /// fetch-only path). Called after `published_sums` so a GitHub handle can
    /// bind against the release tag it just fetched.
    fn anchor_key(&self, entry: &SourceEntry) -> Option<String>;

    /// Source-coverage direction check (the AUR rule). Default: covered.
    fn check_coverage(&self, _info: &RecipeInfo) -> Coverage {
        Coverage::Covered { extras: Vec::new() }
    }
}

/// The recipe facts a provider and the rewrite need: expanded arrays read the
/// way `makepkg` reads them, never guessed from text.
#[derive(Clone, Debug)]
pub struct RecipeInfo {
    /// The recipe directory.
    pub dir: PathBuf,
    /// `pkgbase`, or the single pkgname, or the directory name.
    pub pkgbase: String,
    /// Every split output name.
    pub pkgnames: Vec<String>,
    /// The expanded `source=()` array.
    pub sources: Vec<SourceEntry>,
    /// The evaluated `pkgver`.
    pub pkgver: String,
    /// The evaluated `pkgrel` (default `1`).
    pub pkgrel: String,
    /// The evaluated `epoch` (default `0`).
    pub epoch: String,
}

impl RecipeInfo {
    /// Read (or re-read, after a rewrite) the recipe's evaluated facts.
    pub fn read(recipe_dir: &Path) -> Result<RecipeInfo, EvalError> {
        let pkgbase_var = pkgbuild_var(recipe_dir, "pkgbase").unwrap_or_default();
        let pkgnames = pkgbuild_array_checked(recipe_dir, "pkgname")?;
        let pkgbase = if !pkgbase_var.is_empty() {
            pkgbase_var
        } else if pkgnames.len() == 1 {
            pkgnames[0].clone()
        } else {
            recipe_dir
                .file_name()
                .map(|s| s.to_string_lossy().to_string())
                .unwrap_or_default()
        };
        let sources = pkgbuild_array_checked(recipe_dir, "source")?
            .into_iter()
            .map(SourceEntry::new)
            .collect();
        let pkgver = pkgbuild_var(recipe_dir, "pkgver")?;
        let pkgrel = pkgbuild_var(recipe_dir, "pkgrel")?;
        let epoch = pkgbuild_var(recipe_dir, "epoch").unwrap_or_default();
        Ok(RecipeInfo {
            dir: recipe_dir.to_path_buf(),
            pkgbase,
            pkgnames,
            sources,
            pkgver,
            pkgrel: if pkgrel.is_empty() {
                "1".into()
            } else {
                pkgrel
            },
            epoch: if epoch.is_empty() { "0".into() } else { epoch },
        })
    }
}

// ---------------------------------------------------------------------------
// .SRCINFO parsing (the anchoring document)
// ---------------------------------------------------------------------------

/// Checksum map of one `.SRCINFO` document: file → (algorithm, value), read
/// from the *pkgbase* section. makepkg writes every `source =` line in order
/// and then each checksum array in order, brace-expanded and already aligned —
/// but only WITHIN one algorithm (fish ships one source with both a sha512 and
/// a b2 sum, so a flat list is not aligned). Only the first contiguous run of
/// one algorithm is used, and only when it is exactly as long as the source
/// list; an unparseable file is never an anchor. `SKIP`/empty values are
/// absent from the map (they are refresh-only).
pub fn srcinfo_sum_map(text: &str) -> Option<(BTreeMap<String, PublishedSum>, String)> {
    let mut srcs: Vec<String> = Vec::new();
    let mut algos: Vec<String> = Vec::new();
    let mut vals: Vec<String> = Vec::new();
    for line in text.lines() {
        let t = line.trim_start();
        if srcinfo_field(t, "pkgname").is_some() {
            break;
        }
        if let Some(v) = srcinfo_field(t, "source") {
            srcs.push(v);
            continue;
        }
        for alg in ["sha256", "sha512", "b2", "md5"] {
            if let Some(v) = srcinfo_field(t, &format!("{alg}sums")) {
                algos.push(alg.to_string());
                vals.push(v);
            }
        }
    }
    if srcs.is_empty() || algos.len() < srcs.len() {
        return None;
    }
    let first = algos[0].clone();
    let run = algos.iter().take_while(|a| **a == first).count();
    if run != srcs.len() {
        return None;
    }
    let mut map = BTreeMap::new();
    for (i, src) in srcs.iter().enumerate() {
        let val = &vals[i];
        if val.is_empty() || val == "SKIP" {
            continue;
        }
        if let Some(file) = SourceEntry::new(src.clone()).filename() {
            map.insert(
                file,
                PublishedSum {
                    algorithm: first.clone(),
                    value: val.to_ascii_lowercase(),
                },
            );
        }
    }
    Some((map, first))
}

fn srcinfo_field<'a>(line: &'a str, field: &str) -> Option<String> {
    let rest = line.strip_prefix(field)?;
    let v = rest.trim_start().strip_prefix('=')?;
    Some(v.trim_start().to_string())
}

/// The base-section scalar of a provider `.SRCINFO` (`pkgbase`, `pkgver`,
/// `pkgrel`, `epoch`), read up to the first `pkgname` line.
pub fn srcinfo_base_value(text: &str, field: &str) -> Option<String> {
    for line in text.lines() {
        let t = line.trim_start();
        if srcinfo_field(t, "pkgname").is_some() {
            break;
        }
        if let Some(v) = srcinfo_field(t, field) {
            return Some(v);
        }
    }
    None
}

/// The base-section `source =` lines of a provider `.SRCINFO` — the coverage
/// direction check reads these verbatim.
pub fn srcinfo_base_sources(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    for line in text.lines() {
        let t = line.trim_start();
        if srcinfo_field(t, "pkgname").is_some() {
            break;
        }
        if let Some(v) = srcinfo_field(t, "source") {
            out.push(v);
        }
    }
    out
}

/// Coverage direction, the 2026-10-07 rule: every recipe source must appear
/// verbatim in the published list; a published superset is valid and its
/// extras are reported; a recipe superset refuses.
pub fn source_coverage(recipe_sources: &[SourceEntry], published: &[String]) -> Coverage {
    if recipe_sources.is_empty() && !published.is_empty() {
        return Coverage::NotCovered {
            missing: published.to_vec(),
        };
    }
    let mut missing = Vec::new();
    for s in recipe_sources {
        if !published.iter().any(|p| *p == s.0) {
            missing.push(s.0.clone());
        }
    }
    if !missing.is_empty() {
        return Coverage::NotCovered { missing };
    }
    let extras = published
        .iter()
        .filter(|p| !recipe_sources.iter().any(|s| s.0 == **p))
        .cloned()
        .collect();
    Coverage::Covered { extras }
}

// ---------------------------------------------------------------------------
// Hashing (the artifact mediates: algorithms need not match)
// ---------------------------------------------------------------------------

/// Hash bytes with a provider-published algorithm. sha256/sha512 are native
/// (sha2); md5/b2 ride their coreutils tools through PATH like the fish
/// reference's `"$alg"sum`. `None` = unsupported algorithm.
pub fn hash_bytes(alg: &str, data: &[u8]) -> Option<String> {
    match alg {
        "sha256" => {
            use sha2::{Digest, Sha256};
            Some(hex(&Sha256::digest(data)))
        }
        "sha512" => {
            use sha2::{Digest, Sha512};
            Some(hex(&Sha512::digest(data)))
        }
        _ => None,
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Hash a fetched file. md5/b2 shell out (`md5sum`/`b2sum`, PATH); a missing
/// tool reads as "cannot verify" (an absence, never a disagreement).
pub fn hash_file(alg: &str, path: &Path) -> Option<String> {
    if matches!(alg, "sha256" | "sha512") {
        let data = fs::read(path).ok()?;
        return hash_bytes(alg, &data);
    }
    let tool = format!("{alg}sum");
    let out = Command::new(&tool).arg(path).output().ok()?;
    if !out.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&out.stdout);
    let first = text.split_whitespace().next()?;
    if matches!(first.len(), 32 | 64 | 128) {
        Some(first.to_ascii_lowercase())
    } else {
        None
    }
}

/// The outcome of recomputing a VCS source's makepkg checksum.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum VcsSum {
    /// The recomputed digest.
    Sum(String),
    /// No checkout available to recompute against.
    NoCheckout,
    /// `git archive` could not reproduce the archive.
    RecomputeFailed(String),
}

/// makepkg's own checksum for one VCS source: `git archive --format tar <ref>`
/// of the checkout, hashed — reproducible on any machine, which makes the
/// provider's published value a cross-check rather than a local echo (fish
/// 4.9.3 and ccache 4.14 matched Arch byte for byte). The archive is captured
/// to memory and any git failure is a failure: a failing git must not hash
/// empty input and report a confident wrong sum.
pub fn vcs_source_sum(recipe_dir: &Path, entry: &SourceEntry, alg: &str) -> VcsSum {
    let Some((_, value)) = entry.vcs_ref() else {
        return VcsSum::NoCheckout;
    };
    let Some(name) = entry.filename() else {
        return VcsSum::NoCheckout;
    };
    // makepkg's get_filename strips a trailing `.git` (the clone of
    // …/pipewire.git lands in `pipewire`), while the provider map is keyed by
    // the URL spelling — try both (2026-09-30).
    let stripped = name.strip_suffix(".git").unwrap_or(&name).to_string();
    let mut roots = vec![recipe_dir.to_path_buf()];
    // The resolved SRCDEST (the build user's makepkg.conf), never the raw
    // env alone — see `gsa_model::config::resolve_srcdest`.
    if let Some(srcdest) = gsa_model::config::resolve_srcdest() {
        roots.push(srcdest);
    }
    let mut repo = None;
    'outer: for root in &roots {
        for cand in [&name, &stripped] {
            let p = root.join(cand);
            if p.is_dir() {
                repo = Some(p);
                break 'outer;
            }
        }
    }
    let Some(repo) = repo else {
        return VcsSum::NoCheckout;
    };
    let out = match Command::new("git")
        .arg("-c")
        .arg("core.abbrev=no")
        .arg("-C")
        .arg(&repo)
        .arg("archive")
        .arg("--format")
        .arg("tar")
        .arg(&value)
        .output()
    {
        Ok(o) => o,
        Err(e) => return VcsSum::RecomputeFailed(format!("{e}")),
    };
    if !out.status.success() {
        return VcsSum::RecomputeFailed(format!("git archive exited {}", out.status));
    }
    match hash_bytes(alg, &out.stdout) {
        Some(s) => VcsSum::Sum(s),
        None => VcsSum::RecomputeFailed(format!("cannot hash a git archive with {alg}")),
    }
}

// ---------------------------------------------------------------------------
// Production providers (PATH-shelling)
// ---------------------------------------------------------------------------

/// The Arch official provider: versions from `pacman -Si` (`LC_ALL=C` so the
/// not-found text is the parseable English spelling), published checksums
/// from the official packaging repo's `.SRCINFO`
/// (`gitlab.archlinux.org/archlinux/packaging/packages/<name>/-/raw/<ref>/.SRCINFO`,
/// `main` first with the version's own tag `<pkgver>-<pkgrel>` as fallback —
/// `main` can be ahead of the repos, bash 5.3.20 vs 5.3.15).
#[derive(Clone, Debug, Default)]
pub struct ArchOfficial;

impl VersionProvider for ArchOfficial {
    fn label(&self) -> String {
        "Arch repo".to_string()
    }

    fn family(&self) -> ProviderFamily {
        ProviderFamily::Arch
    }

    fn required_tools(&self) -> Vec<&'static str> {
        vec!["curl"]
    }

    fn query_name(&self, name: &str) -> Result<VersionAnswer, ProviderError> {
        let out = Command::new("pacman")
            .env("LC_ALL", "C")
            .arg("-Si")
            .arg(name)
            .output()
            .map_err(|e| ProviderError::ToolMissing(format!("pacman: {e}")))?;
        let text = String::from_utf8_lossy(&out.stdout).to_string();
        let err_text = String::from_utf8_lossy(&out.stderr).to_string();
        let combined = format!("{text}{err_text}");
        if out.status.success() {
            if text.trim().is_empty() {
                // A zero-exit answer that advertises nothing: nothing to sync to.
                return Ok(VersionAnswer::UnknownName);
            }
            let version = text
                .lines()
                .find_map(|l| l.strip_prefix("Version"))
                .and_then(|l| l.trim_start().strip_prefix(':'))
                .map(|v| v.trim().to_string())
                .unwrap_or_default();
            if version.is_empty() {
                return Ok(VersionAnswer::UnknownName);
            }
            return match VersionFields::parse(&version) {
                Some(v) => Ok(VersionAnswer::Found(v)),
                None => Ok(VersionAnswer::QueryFailed(format!(
                    "cannot parse repository version '{version}'"
                ))),
            };
        }
        if combined.contains("was not found") {
            return Ok(VersionAnswer::UnknownName);
        }
        Ok(VersionAnswer::QueryFailed(combined.trim().to_string()))
    }

    fn release_metadata(
        &self,
        _info: &RecipeInfo,
        _pkgver: &str,
    ) -> Result<ReleaseMetadata, ProviderError> {
        // Arch's release metadata is the repo `Version` parse itself.
        Err(ProviderError::Unsupported(
            "Arch release metadata comes from pacman -Si".into(),
        ))
    }

    fn published_sums(
        &self,
        info: &RecipeInfo,
        version: &VersionFields,
    ) -> Result<PublishedSums, ProviderError> {
        let mut candidates = vec![info.pkgbase.clone()];
        candidates.extend(info.pkgnames.iter().cloned());
        let mut tried: Vec<String> = Vec::new();
        let mut seen: Option<(String, String)> = None;
        for c in candidates {
            if c.is_empty() || tried.contains(&c) {
                continue;
            }
            tried.push(c.clone());
            for ref_name in [
                "main".to_string(),
                format!("{}-{}", version.pkgver, version.pkgrel),
            ] {
                let url = format!(
                    "https://gitlab.archlinux.org/archlinux/packaging/packages/{c}/-/raw/{ref_name}/.SRCINFO"
                );
                let text = match fetch_to_string(&url)? {
                    Some(t) => t,
                    None => continue,
                };
                if text.trim().is_empty() {
                    continue;
                }
                // A revision that does not carry our pkgver is no anchor: it
                // describes different files.
                let v = srcinfo_base_value(&text, "pkgver").unwrap_or_default();
                if v.is_empty() {
                    continue;
                }
                if v == version.pkgver {
                    let (map, _) = srcinfo_sum_map(&text).ok_or_else(|| {
                        ProviderError::Invalid(format!(
                            "the official .SRCINFO for {c} does not line its sources up with its checksums, so it cannot be used as an anchor"
                        ))
                    })?;
                    let mut extras = Vec::new();
                    for key in map.keys() {
                        if !info
                            .sources
                            .iter()
                            .any(|s| s.filename().as_deref() == Some(key.as_str()))
                        {
                            extras.push(key.clone());
                        }
                    }
                    return Ok(PublishedSums {
                        entries: map,
                        extras,
                        published_id: c.clone(),
                    });
                }
                seen = Some((c.clone(), v));
            }
        }
        Err(match seen {
            Some((c, v)) => ProviderError::Invalid(format!(
                "pkgver was synced, but the official packaging repo carries {v} (read from the .SRCINFO of the official {c} packaging repo; anchoring to another version's checksums would describe different files)"
            )),
            None => ProviderError::Invalid(format!(
                "the official Arch packaging repo carries no revision of {} at that version to anchor the checksums to",
                info.pkgbase
            )),
        })
    }

    fn anchor_key(&self, entry: &SourceEntry) -> Option<String> {
        entry.filename()
    }
}

/// Fetch a URL with `curl` through PATH. `Ok(None)` = a clean HTTP 404 (the
/// `main`-vs-tag fallback depends on distinguishing "absent" from "broken").
fn fetch_to_string(url: &str) -> Result<Option<String>, ProviderError> {
    let out = Command::new("curl")
        .arg("--silent")
        .arg("--show-error")
        .arg("--location")
        .arg("--max-time")
        .arg("60")
        .arg("--connect-timeout")
        .arg("10")
        .arg("--write-out")
        .arg("%{http_code}")
        .arg(url)
        .output()
        .map_err(|e| ProviderError::ToolMissing(format!("curl: {e}")))?;
    let raw = String::from_utf8_lossy(&out.stdout).to_string();
    let (body, code) = split_write_out(&raw);
    if !out.status.success() {
        return match code.as_str() {
            "404" => Ok(None),
            _ => Err(ProviderError::Outage(format!(
                "curl exit {} fetching {url}",
                out.status
            ))),
        };
    }
    match code.as_str() {
        "200" => Ok(Some(body)),
        "404" => Ok(None),
        _ => Err(ProviderError::Outage(format!("HTTP {code} fetching {url}"))),
    }
}

fn split_write_out(stdout: &str) -> (String, String) {
    // curl appends the write-out template after the body; the code is the
    // trailing 3-digit run.
    let trimmed = stdout.trim_end_matches('\n');
    if trimmed.len() >= 3 {
        let tail = &trimmed[trimmed.len() - 3..];
        if tail.chars().all(|c| c.is_ascii_digit()) {
            return (trimmed[..trimmed.len() - 3].to_string(), tail.to_string());
        }
    }
    (trimmed.to_string(), String::new())
}

/// The nvchecker runner of the opted-in path: merges a disposable
/// `old_ver.json`/`new_ver.json` state OUTSIDE the repository into a temp
/// config, runs ONLY that one section's config through `nvchecker` (PATH),
/// and reads the resolved version out of `new_ver.json` with serde_json —
/// accepting both nvchecker state shapes (the legacy flat
/// `{key: "version"}` map and the v2 envelope
/// `{"version": 2, "data": {key: {"version": …}}}` of nvchecker 2.22; the
/// flat-only reader deferred gcc-snapshot for a day, 2026-10-07).
#[derive(Clone, Debug)]
pub struct NvcheckerRunner {
    /// The recipe's `.nvchecker.toml`.
    pub config: PathBuf,
    /// Repository root for the scratch-safety gate.
    pub repo_root: PathBuf,
}

impl NvcheckerRunner {
    /// Classify the selected config section: the provider family and its
    /// identity. Unsupported version mappings refuse — never guessed.
    pub fn provider_identity(&self, key: &str) -> Result<(ProviderFamily, String), ProviderError> {
        let text = fs::read_to_string(&self.config)
            .map_err(|e| ProviderError::Invalid(format!("cannot read nvchecker config: {e}")))?;
        let section = toml_section(&text, key).ok_or_else(|| {
            ProviderError::Invalid(format!(
                "no such section {key:?} in {}",
                self.config.display()
            ))
        })?;
        let source = toml_str_value(&section, "source").unwrap_or_default();
        match source.as_str() {
            "aur" => {
                let id = toml_str_value(&section, "aur").unwrap_or_default();
                if id.is_empty()
                    || !id.chars().all(|c| {
                        c.is_ascii_alphanumeric() || matches!(c, '@' | '.' | '_' | '+' | '-')
                    })
                    || id == "."
                    || id == ".."
                {
                    return Err(ProviderError::Invalid(
                        "section has an invalid AUR identity".into(),
                    ));
                }
                Ok((ProviderFamily::Aur, id))
            }
            "github" => {
                let id = toml_str_value(&section, "github").unwrap_or_default();
                validate_github_identity(&id)?;
                Ok((ProviderFamily::Github, id))
            }
            "git" => {
                let remote = toml_str_value(&section, "git").unwrap_or_default();
                if !remote.starts_with("https://github.com/")
                    || remote.contains('?')
                    || remote.contains('#')
                {
                    return Err(ProviderError::Unsupported(
                        "only GitHub Git sources are supported".into(),
                    ));
                }
                let id = remote
                    .trim_end_matches('/')
                    .strip_prefix("https://github.com/")
                    .unwrap_or("")
                    .strip_suffix(".git")
                    .unwrap_or_else(|| {
                        remote
                            .trim_end_matches('/')
                            .strip_prefix("https://github.com/")
                            .unwrap_or("")
                    })
                    .to_string();
                validate_github_identity(&id)?;
                Ok((ProviderFamily::Github, id))
            }
            other => Err(ProviderError::Unsupported(format!(
                "unsupported version provider source '{other}'"
            ))),
        }
    }

    /// Resolve the version for one section key with disposable state outside
    /// the repository; the state dir honours `$TMPDIR` exactly as the scratch
    /// gate does.
    pub fn resolve(&self, key: &str) -> Result<String, ProviderError> {
        let scratch = ScratchDir::new("nvcheck", &self.repo_root)
            .map_err(|e| ProviderError::Invalid(e.message))?;
        let state = scratch.path().join("state");
        fs::create_dir_all(&state).map_err(|e| ProviderError::Invalid(format!("{e}")))?;
        let oldver = state.join("old_ver.json");
        let newver = state.join("new_ver.json");
        let config_text = fs::read_to_string(&self.config)
            .map_err(|e| ProviderError::Invalid(format!("cannot read nvchecker config: {e}")))?;
        if config_text
            .lines()
            .any(|l| l.trim_start().starts_with("[__config__]"))
        {
            return Err(ProviderError::Invalid(
                "config already defines [__config__]; cannot inject resolver state".into(),
            ));
        }
        let merged = scratch.path().join("config.toml");
        let body = format!(
            "[__config__]\noldver = \"{}\"\nnewver = \"{}\"\n\n{}",
            oldver.display(),
            newver.display(),
            config_text
        );
        fs::write(&merged, body).map_err(|e| ProviderError::Invalid(format!("{e}")))?;
        let out = Command::new("nvchecker")
            .arg("-c")
            .arg(&merged)
            .output()
            .map_err(|e| ProviderError::ToolMissing(format!("nvchecker: {e}")))?;
        if !out.status.success() {
            return Err(ProviderError::Outage(format!(
                "nvchecker failed for {} key {key} (exit {})",
                self.config.display(),
                out.status
            )));
        }
        let raw = fs::read_to_string(&newver)
            .map_err(|e| ProviderError::Invalid(format!("cannot read new_ver.json: {e}")))?;
        let value: serde_json::Value = serde_json::from_str(&raw)
            .map_err(|e| ProviderError::Invalid(format!("cannot parse new_ver.json: {e}")))?;
        let table = match (value.get("version"), value.get("data")) {
            (Some(_), Some(data)) if data.is_object() => data.clone(),
            _ => value.clone(),
        };
        let entry = table.get(key).and_then(|e| match e {
            serde_json::Value::String(s) => Some(s.clone()),
            serde_json::Value::Object(_) => {
                e.get("version").and_then(|v| v.as_str()).map(String::from)
            }
            _ => None,
        });
        match entry {
            Some(v) if !v.is_empty() && !v.chars().any(|c| c.is_whitespace()) => Ok(v),
            _ => Err(ProviderError::Invalid(format!(
                "new_ver.json has no version for key {key:?}"
            ))),
        }
    }
}

fn validate_github_identity(id: &str) -> Result<(), ProviderError> {
    let parts: Vec<&str> = id.split('/').collect();
    let ok = parts.len() == 2
        && parts.iter().all(|p| {
            !p.is_empty()
                && *p != "."
                && *p != ".."
                && p.chars()
                    .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '-'))
        });
    if ok {
        Ok(())
    } else {
        Err(ProviderError::Invalid(
            "section has an invalid GitHub identity".into(),
        ))
    }
}

/// Minimal strict section reader for `.nvchecker.toml`: finds `[key]` and
/// returns its lines. Anything it cannot classify is refused by the caller,
/// never guessed.
fn toml_section(text: &str, key: &str) -> Option<String> {
    let mut lines = Vec::new();
    let mut in_section = false;
    for line in text.lines() {
        let t = line.trim();
        if t.starts_with('[') {
            if in_section {
                break;
            }
            if t == format!("[{key}]") {
                in_section = true;
            }
            continue;
        }
        if in_section {
            lines.push(line.to_string());
        }
    }
    if in_section {
        Some(lines.join("\n"))
    } else {
        None
    }
}

fn toml_str_value(section: &str, key: &str) -> Option<String> {
    for line in section.lines() {
        let t = line.trim();
        if let Some(rest) = t.strip_prefix(key) {
            let rest = rest.trim_start();
            if let Some(v) = rest.strip_prefix('=') {
                let v = v.trim();
                let v = v
                    .strip_prefix('"')
                    .and_then(|s| s.strip_suffix('"'))
                    .unwrap_or(v);
                return Some(v.to_string());
            }
        }
    }
    None
}

/// The AUR provider of the opted-in path: version via [`NvcheckerRunner`],
/// `pkgrel`/`epoch` and published checksums from the AUR's `.SRCINFO`
/// (`aur.archlinux.org/cgit/aur.git/plain/.SRCINFO?h=<id>`). The document
/// must match the configured pkgbase and the resolved pkgver and must COVER
/// the recipe's expanded sources before it can anchor anything.
#[derive(Clone, Debug)]
pub struct AurProvider {
    /// The nvchecker runner resolving versions for this recipe.
    pub runner: NvcheckerRunner,
    /// The configured AUR identity (pkgbase).
    pub id: String,
    srcinfo: RefCell<Option<String>>,
}

impl AurProvider {
    /// Build a handle for one configured AUR identity.
    pub fn new(runner: NvcheckerRunner, id: String) -> AurProvider {
        AurProvider {
            runner,
            id,
            srcinfo: RefCell::new(None),
        }
    }

    fn fetch_srcinfo(&self) -> Result<String, ProviderError> {
        if let Some(t) = self.srcinfo.borrow().as_ref() {
            return Ok(t.clone());
        }
        let url = format!(
            "https://aur.archlinux.org/cgit/aur.git/plain/.SRCINFO?h={}",
            self.id
        );
        let text = fetch_to_string(&url)?.ok_or_else(|| {
            ProviderError::Outage(format!("AUR .SRCINFO for {} is unavailable", self.id))
        })?;
        *self.srcinfo.borrow_mut() = Some(text.clone());
        Ok(text)
    }
}

impl VersionProvider for AurProvider {
    fn label(&self) -> String {
        format!("AUR {}", self.id)
    }

    fn family(&self) -> ProviderFamily {
        ProviderFamily::Aur
    }

    fn required_tools(&self) -> Vec<&'static str> {
        vec!["curl"]
    }

    fn query_name(&self, name: &str) -> Result<VersionAnswer, ProviderError> {
        match self.runner.resolve(name) {
            Ok(v) => match VersionFields::parse(&format!("{v}-1")) {
                Some(f) => Ok(VersionAnswer::Found(f)),
                None => Ok(VersionAnswer::QueryFailed(format!(
                    "cannot express upstream version '{v}'"
                ))),
            },
            Err(ProviderError::Invalid(m)) if m.contains("no version for key") => {
                Ok(VersionAnswer::UnknownName)
            }
            Err(e) => Err(e),
        }
    }

    fn release_metadata(
        &self,
        info: &RecipeInfo,
        pkgver: &str,
    ) -> Result<ReleaseMetadata, ProviderError> {
        let text = self.fetch_srcinfo()?;
        let base = srcinfo_base_value(&text, "pkgbase").unwrap_or_default();
        let ver = srcinfo_base_value(&text, "pkgver").unwrap_or_default();
        // The document must match the configured identity, the recipe's
        // pkgbase AND the resolved pkgver — a mismatch is an AUR metadata
        // race, deferred and restored, never anchored.
        if base != self.id || base != info.pkgbase || ver != pkgver {
            return Err(ProviderError::Invalid(format!(
                "AUR .SRCINFO changed or disagrees with nvchecker (expected {} {pkgver}, got {base} {ver})",
                self.id
            )));
        }
        let pkgrel = srcinfo_base_value(&text, "pkgrel").unwrap_or_default();
        let epoch = srcinfo_base_value(&text, "epoch").unwrap_or_else(|| "0".to_string());
        if !version_value_ok(VersionField::Pkgrel, &pkgrel)
            || !version_value_ok(VersionField::Epoch, &epoch)
        {
            return Err(ProviderError::Invalid(
                "AUR .SRCINFO has an invalid pkgrel or epoch".into(),
            ));
        }
        Ok(ReleaseMetadata { pkgrel, epoch })
    }

    fn published_sums(
        &self,
        info: &RecipeInfo,
        version: &VersionFields,
    ) -> Result<PublishedSums, ProviderError> {
        let text = self.fetch_srcinfo()?;
        let base = srcinfo_base_value(&text, "pkgbase").unwrap_or_default();
        let ver = srcinfo_base_value(&text, "pkgver").unwrap_or_default();
        if base != self.id || base != info.pkgbase || ver != version.pkgver {
            return Err(ProviderError::Invalid(format!(
                "the AUR .SRCINFO for {} does not match pkgbase {} and pkgver {}",
                self.id, info.pkgbase, version.pkgver
            )));
        }
        match source_coverage(&info.sources, &srcinfo_base_sources(&text)) {
            Coverage::NotCovered { missing } => Err(ProviderError::Invalid(format!(
                "the AUR .SRCINFO for {} does not cover every source of the rewritten recipe (missing: {})",
                self.id,
                missing.join(", ")
            ))),
            Coverage::Covered { extras } => {
                let (entries, _) = srcinfo_sum_map(&text).ok_or_else(|| {
                    ProviderError::Invalid(format!(
                        "the AUR .SRCINFO for {} does not line its sources up with its checksums",
                        self.id
                    ))
                })?;
                Ok(PublishedSums {
                    entries,
                    extras,
                    published_id: self.id.clone(),
                })
            }
        }
    }

    fn anchor_key(&self, entry: &SourceEntry) -> Option<String> {
        entry.filename()
    }

    fn check_coverage(&self, info: &RecipeInfo) -> Coverage {
        match self.fetch_srcinfo() {
            Ok(text) => source_coverage(&info.sources, &srcinfo_base_sources(&text)),
            Err(_) => Coverage::NotCovered {
                missing: info.sources.iter().map(|s| s.0.clone()).collect(),
            },
        }
    }
}

/// The GitHub provider of the opted-in path: version via [`NvcheckerRunner`],
/// `pkgrel` reset to 1 only when `pkgver` moves (the pass applies that rule),
/// published asset digests from the release JSON — bound to the configured
/// repository, the release tag, and the REMOTE URL basename (never a
/// `name::url` local override).
#[derive(Clone, Debug)]
pub struct GithubProvider {
    /// The nvchecker runner resolving versions for this recipe.
    pub runner: NvcheckerRunner,
    /// The configured `owner/repo`.
    pub repo: String,
    release_tag: RefCell<Option<String>>,
    sums: RefCell<PublishedSums>,
}

impl GithubProvider {
    /// Build a handle for one configured repository.
    pub fn new(runner: NvcheckerRunner, repo: String) -> GithubProvider {
        GithubProvider {
            runner,
            repo,
            release_tag: RefCell::new(None),
            sums: RefCell::new(PublishedSums::default()),
        }
    }

    /// Fetch the release JSON for `<tag>`/`v<tag>` and build the digest map.
    /// A release without a matching digest leaves the map empty — the loud
    /// fetch-only path, never a claim of upstream verification.
    fn fetch_release(&self, pkgver: &str) -> Result<(), ProviderError> {
        let mut found = None;
        for tag in [pkgver.to_string(), format!("v{pkgver}")] {
            let url = format!(
                "https://api.github.com/repos/{}/releases/tags/{tag}",
                self.repo
            );
            let body = match fetch_to_string(&url)? {
                Some(b) => b,
                None => continue,
            };
            let value: serde_json::Value = serde_json::from_str(&body).map_err(|e| {
                ProviderError::Invalid(format!("cannot parse GitHub release JSON: {e}"))
            })?;
            if value.get("tag_name").and_then(|t| t.as_str()) != Some(tag.as_str()) {
                return Err(ProviderError::Invalid(
                    "GitHub release metadata does not match the requested tag".into(),
                ));
            }
            let assets = value
                .get("assets")
                .and_then(|a| a.as_array())
                .ok_or_else(|| {
                    ProviderError::Invalid(
                        "GitHub release metadata has no valid assets list".into(),
                    )
                })?;
            let mut entries = BTreeMap::new();
            let mut seen = BTreeSet::new();
            for asset in assets {
                let name = asset
                    .get("name")
                    .and_then(|n| n.as_str())
                    .filter(|n| !n.is_empty() && !n.contains(['\t', '\r', '\n']))
                    .ok_or_else(|| {
                        ProviderError::Invalid(
                            "GitHub release metadata contains an invalid asset name".into(),
                        )
                    })?;
                if !seen.insert(name.to_string()) {
                    return Err(ProviderError::Invalid(format!(
                        "GitHub release has duplicate asset name {name:?}"
                    )));
                }
                let Some(digest) = asset.get("digest").and_then(|d| d.as_str()) else {
                    continue; // no published digest: refresh-only
                };
                let Some((alg, value)) = digest.split_once(':') else {
                    return Err(ProviderError::Invalid(format!(
                        "GitHub asset {name:?} has an unsupported digest"
                    )));
                };
                let ok_len = matches!(
                    (alg, value.len()),
                    ("sha256", 64) | ("sha512", 128) | ("md5", 32) | ("b2", 128)
                ) && value.chars().all(|c| c.is_ascii_hexdigit());
                if !ok_len {
                    return Err(ProviderError::Invalid(format!(
                        "GitHub asset {name:?} has an unsupported digest"
                    )));
                }
                entries.insert(
                    name.to_string(),
                    PublishedSum {
                        algorithm: alg.to_string(),
                        value: value.to_ascii_lowercase(),
                    },
                );
            }
            found = Some((tag, entries));
            break;
        }
        match found {
            Some((tag, entries)) => {
                *self.release_tag.borrow_mut() = Some(tag);
                *self.sums.borrow_mut() = PublishedSums {
                    entries,
                    extras: Vec::new(),
                    published_id: self.repo.clone(),
                };
            }
            None => {
                *self.release_tag.borrow_mut() = None;
                *self.sums.borrow_mut() = PublishedSums {
                    entries: BTreeMap::new(),
                    extras: Vec::new(),
                    published_id: self.repo.clone(),
                };
            }
        }
        Ok(())
    }
}

impl VersionProvider for GithubProvider {
    fn label(&self) -> String {
        format!("GitHub {}", self.repo)
    }

    fn family(&self) -> ProviderFamily {
        ProviderFamily::Github
    }

    fn required_tools(&self) -> Vec<&'static str> {
        vec!["curl"]
    }

    fn query_name(&self, name: &str) -> Result<VersionAnswer, ProviderError> {
        match self.runner.resolve(name) {
            Ok(v) => match VersionFields::parse(&format!("{v}-1")) {
                Some(f) => Ok(VersionAnswer::Found(f)),
                None => Ok(VersionAnswer::QueryFailed(format!(
                    "cannot express upstream version '{v}'"
                ))),
            },
            Err(ProviderError::Invalid(m)) if m.contains("no version for key") => {
                Ok(VersionAnswer::UnknownName)
            }
            Err(e) => Err(e),
        }
    }

    fn release_metadata(
        &self,
        _info: &RecipeInfo,
        _pkgver: &str,
    ) -> Result<ReleaseMetadata, ProviderError> {
        // GitHub carries no separate release metadata: the pass resets pkgrel
        // to 1 when pkgver moves and retains a local pkgrel at parity.
        Ok(ReleaseMetadata {
            pkgrel: "1".to_string(),
            epoch: "0".to_string(),
        })
    }

    fn published_sums(
        &self,
        _info: &RecipeInfo,
        version: &VersionFields,
    ) -> Result<PublishedSums, ProviderError> {
        self.fetch_release(&version.pkgver)?;
        Ok(self.sums.borrow().clone())
    }

    fn anchor_key(&self, entry: &SourceEntry) -> Option<String> {
        // Bound to configured repository + release tag + remote URL basename:
        // a `name::url` source resolves its ASSET by the remote basename while
        // `name` stays the local fetched file. Anything outside the release
        // download pattern cannot bind and is refresh-only.
        let tag = self.release_tag.borrow().clone()?;
        let url = entry.url()?.to_string();
        let url = match url.find(['?', '#']) {
            Some(i) => &url[..i],
            None => &url,
        };
        let prefix = format!(
            "https://github.com/{}/releases/download/{}/",
            self.repo, tag
        );
        let asset = url.strip_prefix(&prefix)?;
        if asset.is_empty() || asset.contains('/') {
            return None;
        }
        Some(asset.to_string())
    }
}

// ---------------------------------------------------------------------------
// Anchoring
// ---------------------------------------------------------------------------

/// The exact deferral reason keys of contract §H.3.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DeferReason {
    /// `anchoring-refused`: the checksum anchor could not be established
    /// (provider outage, no official revision at our version, unparseable
    /// anchor, checkout not recomputable, `updpkgsums` failure, missing
    /// tools).
    AnchoringRefused,
    /// `source-unfetchable`: the sources were absent at anchoring time.
    SourceUnfetchable,
}

impl DeferReason {
    /// The §H.3 reason key, verbatim.
    pub fn key(self) -> &'static str {
        match self {
            DeferReason::AnchoringRefused => "anchoring-refused",
            DeferReason::SourceUnfetchable => "source-unfetchable",
        }
    }
}

/// The result of the RULE-18 anchoring procedure.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AnchorOutcome {
    /// No moved entry is a download a published checksum could describe.
    NothingToDo,
    /// Every published value matched the fetched bytes; refresh-only entries
    /// are named loudly.
    Anchored {
        /// How many entries verified against published values.
        anchored: usize,
        /// Files refreshed from the fetch with NO published value (fetch-only).
        refresh_only: Vec<String>,
        /// The identity whose revision carries the sums.
        published: String,
        /// The version the sums were anchored at.
        pkgver: String,
        /// The committed `.SRCINFO` refresh result.
        srcinfo: SrcinfoRefresh,
    },
    /// Nothing published a checksum at all — refreshed from the fetch, never
    /// claimed as upstream verification.
    RefreshOnly {
        /// Files refreshed from the fetch with NO published value.
        files: Vec<String>,
        /// The identity whose revision was queried.
        published: String,
        /// The version refreshed at.
        pkgver: String,
        /// The committed `.SRCINFO` refresh result.
        srcinfo: SrcinfoRefresh,
    },
    /// Impossible to anchor: parked, rewrite restored. Never a license to
    /// build on a fetch-generated hash.
    Defer {
        /// The §H.3 reason key.
        reason: DeferReason,
        /// The named failure.
        message: String,
        /// What the restore achieved.
        restored: RestoreStatus,
    },
    /// A source DISAGREES with the provider's published checksum — an
    /// integrity stop that stops the dispatch like a failed build and
    /// restores the recipe byte-for-byte. A different source, not a stale sum.
    IntegrityStop {
        /// The file that disagrees.
        file: String,
        /// The provider's published digest.
        want: String,
        /// What the fetched source hashes to.
        got: String,
        /// What the restore achieved.
        restored: RestoreStatus,
    },
    /// A published value exists but cannot be checked (unsupported
    /// algorithm) — anchor-or-refuse: it refuses.
    Refused {
        /// The offending file, when known.
        file: Option<String>,
        /// The named refusal.
        message: String,
        /// What the restore achieved.
        restored: RestoreStatus,
    },
}

impl AnchorOutcome {
    /// What the anchor attempt's restore achieved. Success variants have
    /// nothing to restore; failure variants report the measured status.
    pub fn restored(&self) -> RestoreStatus {
        match self {
            AnchorOutcome::Defer { restored, .. }
            | AnchorOutcome::IntegrityStop { restored, .. }
            | AnchorOutcome::Refused { restored, .. } => restored.clone(),
            _ => RestoreStatus::NothingToRestore,
        }
    }

    /// The loud log lines the fish package log and run summary carry for
    /// this outcome, in its message shape (including the refresh-only record
    /// and its attestation text).
    pub fn log_lines(&self, pkg: &str, owner: &str) -> Vec<String> {
        match self {
            AnchorOutcome::NothingToDo => Vec::new(),
            AnchorOutcome::Anchored {
                anchored,
                refresh_only,
                published,
                pkgver,
                ..
            } => {
                let mut out = Vec::new();
                if !refresh_only.is_empty() {
                    out.push(format!(
                        "⚠ {pkg}: {owner} {published} {pkgver} publishes no checksum for (refreshed from the fetch, NOT anchored):"
                    ));
                    for f in refresh_only {
                        out.push(format!("    {f}"));
                    }
                    out.push(refresh_only_attestation());
                }
                if *anchored > 0 {
                    out.push(format!(
                        "ℹ {pkg}: checksums re-anchored to {owner} {published} {pkgver} checksums, and verified against the fetched sources"
                    ));
                }
                out
            }
            AnchorOutcome::RefreshOnly {
                files,
                published,
                pkgver,
                ..
            } => {
                let mut out = vec![format!(
                    "⚠ {pkg}: {owner} {published} {pkgver} publishes no checksum for (refreshed from the fetch, NOT anchored):"
                )];
                for f in files {
                    out.push(format!("    {f}"));
                }
                out.push(refresh_only_attestation());
                out.push(format!(
                    "ℹ {pkg}: checksums refreshed for {pkgver} — {owner} {published} publishes no checksum for any moved source"
                ));
                out
            }
            AnchorOutcome::Defer {
                reason, message, ..
            } => vec![
                format!("✗ {pkg}: {message}"),
                format!(
                    "  Deferred ({}). No package was built; retry when provider metadata is available, or use '--no-sync' to build the committed version and sums. Do not treat a fetched hash as an upstream anchor.",
                    reason.key()
                ),
            ],
            AnchorOutcome::IntegrityStop {
                file, want, got, ..
            } => {
                // Owner labels carry their own article ("the official",
                // "the provider") or none ("AUR", "GitHub"), and fish's
                // wording is "the <owner> published checksum" — so the
                // article appears exactly once, never doubled.
                let owner_the = if owner.starts_with("the ") {
                    owner.to_string()
                } else {
                    format!("the {owner}")
                };
                vec![
                    format!(
                        "✗ {pkg}: refusing to build — a source does not match {owner_the} published checksum"
                    ),
                    format!("    {file}: {owner}'s published value is {want}, the fetched source hashes to {got}"),
                    "  Nothing was built or installed and the recipe was restored. A source that disagrees with a published checksum is a different source, not a stale sum.".to_string(),
                ]
            }
            AnchorOutcome::Refused { message, .. } => {
                vec![format!("✗ {pkg}: refusing to build — {message}")]
            }
        }
    }
}

fn refresh_only_attestation() -> String {
    "  Attestation: a detached signature is PGP-verified against the anchored payload at build time, a VCS source is pinned by its #tag/#commit, and a plain download is attested by nothing but the fetch (TLS). Review these sums before committing; '--no-sync' builds the committed version as-is.".to_string()
}

/// The RULE-18 anchoring procedure end to end, over the *moved* entries only
/// (a pkgver rewrite that leaves `source=()` alone — 26 of the 28 stable
/// recipes pin literal versions in their URLs — leaves the committed sums
/// valid; re-anchoring those would be a false alarm).
///
/// Grading comes first: an entry the provider publishes a value for is
/// anchor-or-refuse (verified against the fetched bytes after `updpkgsums`
/// writes the recipe's own sums); an entry it publishes nothing for is
/// refresh-only and recorded loudly. `.sign`/`.sig`/`.asc` are outside
/// checksum anchoring entirely — makepkg verifies them with PGP over the
/// anchored payload, so refreshing their hash would prove nothing.
pub fn anchor_sums(
    tx: &mut RecipeTransaction,
    info: &RecipeInfo,
    provider: &dyn VersionProvider,
    version: &VersionFields,
    moved: &[SourceEntry],
    label_owner: &str,
) -> AnchorOutcome {
    // Candidates: downloads only, deduped by the name makepkg gives them.
    let mut candidates: Vec<(String, SourceEntry)> = Vec::new();
    for e in moved {
        if e.url().is_none() {
            continue;
        }
        let Some(fnm) = e.filename() else {
            continue;
        };
        if candidates.iter().any(|(f, _)| *f == fnm) {
            continue;
        }
        candidates.push((fnm, e.clone()));
    }
    if candidates.is_empty() {
        return AnchorOutcome::NothingToDo;
    }

    // Tool gates: updpkgsums writes the sums (it ships with pacman); the
    // provider declares what else its metadata fetch needs.
    for tool in std::iter::once("updpkgsums").chain(provider.required_tools()) {
        if !tool_on_path(tool) {
            let restored = tx.restore();
            return AnchorOutcome::Defer {
                reason: DeferReason::AnchoringRefused,
                message: format!(
                    "refusing to build — pkgver was synced to {}-{} and '{tool}' is missing, so the checksums cannot be refreshed or read",
                    version.pkgver, version.pkgrel
                ),
                restored,
            };
        }
    }

    let published = match provider.published_sums(info, version) {
        Ok(p) => p,
        Err(ProviderError::Unsupported(m)) => {
            let restored = tx.restore();
            return AnchorOutcome::Refused {
                file: None,
                message: m,
                restored,
            };
        }
        Err(e) => {
            let restored = tx.restore();
            return AnchorOutcome::Defer {
                reason: DeferReason::AnchoringRefused,
                message: format!(
                    "refusing to build — provider checksum metadata is unavailable ({e})"
                ),
                restored,
            };
        }
    };

    // Grade before writing.
    let mut refresh_only: Vec<String> = Vec::new();
    let mut anchored: Vec<(String, PublishedSum)> = Vec::new();
    for (fnm, entry) in &candidates {
        match provider
            .anchor_key(entry)
            .and_then(|k| published.entries.get(&k).map(|s| s.clone()))
        {
            Some(sum) => anchored.push((fnm.clone(), sum)),
            None => refresh_only.push(fnm.clone()),
        }
    }

    tx.mark_dirty();
    // Build-side command (the makepkg family): under a root supervisor this
    // is dropped to the build user like every other one — updpkgsums runs
    // makepkg internally and REFUSES root (2026-10-16 smoke: the plain spawn
    // ran as root and fzf deferred anchoring-refused on makepkg's root
    // refusal).
    let upd = match gsa_model::privilege::build_command("updpkgsums")
        .current_dir(&info.dir)
        .output()
    {
        Ok(o) => o,
        Err(e) => {
            let restored = tx.restore();
            return AnchorOutcome::Defer {
                reason: DeferReason::AnchoringRefused,
                message: format!("'updpkgsums' could not run ({e})"),
                restored,
            };
        }
    };
    if !upd.status.success() {
        let restored = tx.restore();
        let tail = String::from_utf8_lossy(&upd.stderr);
        let tail = tail.lines().rev().take(5).collect::<Vec<_>>().join(" / ");
        return AnchorOutcome::Defer {
            reason: DeferReason::AnchoringRefused,
            message: format!(
                "refusing to build — 'updpkgsums' could not refresh the checksums (exit {}); {tail}",
                upd.status
            ),
            restored,
        };
    }

    // Verify the fetched sources against the provider's values. This is the
    // step that makes the refresh an anchor rather than a rubber stamp: the
    // algorithm need not match ours, because the published hash is checked
    // against the artifact and the artifact is what the recipe's own hash now
    // describes.
    let mut disagreements: Vec<(String, String, String)> = Vec::new();
    let mut unverifiable: Vec<String> = Vec::new();
    let mut refused: Vec<(String, String)> = Vec::new();
    for (fnm, sum) in &anchored {
        if !matches!(sum.algorithm.as_str(), "sha256" | "sha512" | "md5" | "b2") {
            refused.push((
                fnm.clone(),
                format!(
                    "{label_owner} publishes an algorithm this check does not know ('{}')",
                    sum.algorithm
                ),
            ));
            continue;
        }
        let entry = candidates
            .iter()
            .find(|(f, _)| f == fnm)
            .map(|(_, e)| e.clone())
            .expect("anchored entry came from candidates");
        let got = if entry.vcs().is_some() {
            match vcs_source_sum(&info.dir, &entry, &sum.algorithm) {
                VcsSum::Sum(s) => Some(s),
                VcsSum::NoCheckout => {
                    unverifiable.push(format!(
                        "{fnm}: the VCS checkout was not available to recompute {label_owner}'s {} against",
                        sum.algorithm
                    ));
                    None
                }
                VcsSum::RecomputeFailed(m) => {
                    let restored = tx.restore();
                    return AnchorOutcome::Defer {
                        reason: DeferReason::AnchoringRefused,
                        message: format!(
                            "refusing to build — the checkout could not be recomputed ({m})"
                        ),
                        restored,
                    };
                }
            }
        } else {
            match locate_fetched(&info.dir, fnm) {
                Some(p) => hash_file(&sum.algorithm, &p),
                None => {
                    unverifiable.push(format!(
                        "{fnm}: not fetched into the recipe or $SRCDEST, so {label_owner}'s checksum could not be applied to it"
                    ));
                    None
                }
            }
        };
        let Some(got) = got else { continue };
        if got != sum.value {
            disagreements.push((fnm.clone(), sum.value.clone(), got));
        }
    }

    if !refused.is_empty() {
        let (file, message) = refused[0].clone();
        let restored = tx.restore();
        return AnchorOutcome::Refused {
            file: Some(file),
            message,
            restored,
        };
    }
    if !disagreements.is_empty() {
        let (file, want, got) = disagreements[0].clone();
        let restored = tx.restore();
        return AnchorOutcome::IntegrityStop {
            file,
            want,
            got,
            restored,
        };
    }
    if !unverifiable.is_empty() {
        // Every problem is an ABSENCE, not a disagreement: the anchor could
        // not be checked because the source never arrived. Park the recipe
        // (source-unfetchable); never fall back to a fetch-generated hash.
        let restored = tx.restore();
        return AnchorOutcome::Defer {
            reason: DeferReason::SourceUnfetchable,
            message: format!(
                "sources absent at anchoring time — {}",
                unverifiable.join("; ")
            ),
            restored,
        };
    }

    let srcinfo = refresh_package_srcinfo(&info.dir);
    if anchored.is_empty() {
        // Nothing published a checksum for any moved entry: refreshed from
        // the fetch, and never described as upstream verification.
        AnchorOutcome::RefreshOnly {
            files: refresh_only,
            published: published.published_id,
            pkgver: version.pkgver.clone(),
            srcinfo,
        }
    } else {
        AnchorOutcome::Anchored {
            anchored: anchored.len(),
            refresh_only,
            published: published.published_id,
            pkgver: version.pkgver.clone(),
            srcinfo,
        }
    }
}

fn locate_fetched(recipe_dir: &Path, file: &str) -> Option<PathBuf> {
    let p = recipe_dir.join(file);
    if p.is_file() {
        return Some(p);
    }
    // The resolved SRCDEST (the build user's makepkg.conf), never the raw
    // env alone — see `gsa_model::config::resolve_srcdest`.
    if let Some(srcdest) = gsa_model::config::resolve_srcdest() {
        let p = srcdest.join(file);
        if p.is_file() {
            return Some(p);
        }
    }
    None
}

/// PATH lookup for a required tool — resolved through PATH like every other
/// external tool this module runs, never by absolute path.
pub fn tool_on_path(tool: &str) -> bool {
    let Some(paths) = std::env::var_os("PATH") else {
        return false;
    };
    std::env::split_paths(&paths).any(|dir| dir.join(tool).is_file())
}

// ---------------------------------------------------------------------------
// Typed sync outcomes and disposition rows
// ---------------------------------------------------------------------------

/// Why a pass had nothing to do — the rc-0 contract spelled out.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum NoChangeReason {
    /// Not physically staged under `packages/stable` (the Arch path gate).
    NotStableStaged,
    /// `pkgver()`-driven: no literal `pkgver=` line to rewrite.
    PkgverFunction,
    /// The name is not in the repos at all (distinct from a query failure).
    UnknownInRepos,
    /// A higher local content `pkgver` is kept — a downgrade is never written
    /// (repos can game vercmp with an epoch).
    NeverDowngrade,
    /// Already at the repo version and pkgrel.
    Current,
    /// At equal pkgver a local pkgrel ahead is a deliberate bump (ripgrep's
    /// Rust PGO wave carries pkgrel 2 over the repo's 1; rewriting it back
    /// silently re-stamped a PGO build with the pre-PGO identity, 2026-09-28).
    LocalPkgrelAhead,
    /// Nothing changed (nvchecker parity).
    MetadataCurrent,
}

/// Named refusal classes of the rewrite path.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RefusalClass {
    /// The repository/provider version text cannot be written safely (`&`,
    /// `\`, `/`) — refused BEFORE the first write.
    UnsafeVersionText,
    /// The recipe's source/pkgname arrays could not be evaluated.
    EvalFailure,
    /// A staged write or publish failed; the recipe is rolled back.
    WriteFailed,
    /// The rewrite could not be made rollback-safe (scratch/snapshot).
    RollbackUnsafe,
    /// PKGBUILD lacks the literal `pkgver=`/`pkgrel=` fields version sync needs.
    MissingLiteralFields,
    /// A source disagrees with a published checksum (integrity stop).
    IntegrityStop,
}

/// A typed per-recipe sync outcome — the fish return contract (rc 0/1/2/3/4
/// and the rc-99 deferral) as data.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SyncOutcome {
    /// rc 0: nothing to do.
    NoChange {
        /// Why not.
        reason: NoChangeReason,
    },
    /// rc 1: rewritten, and pkgver moved.
    VersionMoved {
        /// The pre-sync `pkgver-pkgrel`.
        old: String,
        /// The post-sync `pkgver-pkgrel`.
        new: String,
        /// The post-rewrite entries that differ positionally.
        moved_sources: Vec<String>,
    },
    /// rc 3: rewritten, but only pkgrel/epoch moved.
    ReleaseMoved {
        /// The pre-sync version.
        old: String,
        /// The post-sync version.
        new: String,
    },
    /// rc 2/4 class: refused or failed; the recipe is rolled back.
    Refused {
        /// Which named refusal.
        class: RefusalClass,
        /// The named failure.
        message: String,
        /// What the restore achieved.
        restored: RestoreStatus,
    },
    /// rc 4: the repo/provider QUERY failed — the committed version's
    /// freshness is UNVERIFIED. The caller defers; this never folds into
    /// "nothing to do".
    QueryFailed {
        /// The query failure text.
        message: String,
    },
    /// Unsupported expression/variable/version mapping (the rc 3/4/5
    /// refusal classes of the computed-pkgver planner).
    Unsupported {
        /// Which named planner refusal.
        class: PkgverPlanError,
        /// The named failure.
        message: String,
        /// What the restore achieved.
        restored: RestoreStatus,
    },
    /// Parked (rc 99 class) with an exact §H.3 reason key.
    Deferred {
        /// The §H.3 reason.
        reason: DeferReason,
        /// The named failure.
        message: String,
        /// What the restore achieved.
        restored: RestoreStatus,
    },
}

/// One line of the run-level `Version and checksum sync this run` block.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DispositionRow {
    /// `<pkg>: <old-ver> → <new-ver> (synced with <provider>)`.
    VersionSynced {
        /// The recipe's pkgbase.
        pkg: String,
        /// Pre-sync `pkgver-pkgrel`.
        old: String,
        /// Post-sync `pkgver-pkgrel`.
        new: String,
        /// The provider label ("Arch repo", "AUR <id>", "GitHub <repo>").
        provider: String,
        /// Committed `.SRCINFO` refresh result (its failure suffix rides the
        /// same line).
        srcinfo: SrcinfoRefresh,
    },
    /// `<pkg>: checksums refreshed at <ver> — <n> anchored to <provider>,
    /// <m> refresh-only (fetch-only sums: review before committing)`.
    ChecksumsRefreshed {
        /// The recipe's pkgbase.
        pkg: String,
        /// The version the sums were refreshed at.
        ver: String,
        /// Entries anchored to published values.
        anchored: usize,
        /// The anchor authority ("the official bash", "AUR <id>", …).
        provider: String,
        /// Entries refreshed from the fetch only (fetch-only sums).
        refresh_only: usize,
        /// Committed `.SRCINFO` refresh result.
        srcinfo: SrcinfoRefresh,
    },
}

/// Render the run-level disposition block in the `docs/build-guide.md` shape.
/// A run never commits; the disposition of these edits is the maintainer's.
pub fn render_disposition(rows: &[DispositionRow]) -> String {
    if rows.is_empty() {
        return String::new();
    }
    let mut out = String::from(
        "Version and checksum sync this run (uncommitted — review with 'git diff', then commit):\n",
    );
    for row in rows {
        match row {
            DispositionRow::VersionSynced {
                pkg,
                old,
                new,
                provider,
                srcinfo,
            } => {
                out.push_str(&format!(
                    "  {pkg}: {old} → {new} (synced with {provider}){}\n",
                    srcinfo.witness_suffix()
                ));
            }
            DispositionRow::ChecksumsRefreshed {
                pkg,
                ver,
                anchored,
                provider,
                refresh_only,
                srcinfo,
            } => {
                let line = if *refresh_only > 0 {
                    format!(
                        "{pkg}: checksums refreshed at {ver} — {anchored} anchored to {provider}, {refresh_only} refresh-only (fetch-only sums: review before committing)"
                    )
                } else {
                    // The fish witness's m==0 spelling; the refreshed-at line
                    // would claim fetch-only sums that do not exist.
                    format!("{pkg}: checksums re-anchored to {provider} {ver}")
                };
                out.push_str(&format!("  {line}{}\n", srcinfo.witness_suffix()));
            }
        }
    }
    out
}

/// The typed per-recipe report of one pass; the CLI turns `rows` into the
/// disposition block and keeps `log` in the package log / run summary.
#[derive(Clone, Debug)]
pub struct SyncReport {
    /// The recipe's directory name.
    pub pkg: String,
    /// The typed outcome.
    pub outcome: SyncOutcome,
    /// The anchoring result, when the pass reached it.
    pub anchor: Option<AnchorOutcome>,
    /// Disposition rows for the run-level block.
    pub rows: Vec<DispositionRow>,
    /// The complete loud render (owner-labelled anchor lines, integrity
    /// message, provider extras note): callers print it verbatim and never
    /// re-render the anchor with a guessed owner label.
    pub log: Vec<String>,
}

impl SyncReport {
    fn nochange(pkg: String, reason: NoChangeReason) -> SyncReport {
        SyncReport {
            pkg,
            outcome: SyncOutcome::NoChange { reason },
            anchor: None,
            rows: Vec::new(),
            log: Vec::new(),
        }
    }

    /// Is this a deferral, and with which §H.3 key?
    pub fn deferral(&self) -> Option<&'static str> {
        match &self.outcome {
            SyncOutcome::Deferred { reason, .. } => Some(reason.key()),
            _ => self.anchor.as_ref().and_then(|a| match a {
                AnchorOutcome::Defer { reason, .. } => Some(reason.key()),
                _ => None,
            }),
        }
    }
}

/// Policy flags of a pass. `--no-sync` never reaches a pass — the CLI skips
/// the call entirely, which is what makes "no provider query, no rewrite, no
/// anchoring, no refusal" true by construction.
pub struct SyncPolicy {
    /// Repository root: the physical `packages/stable` placement gate and the
    /// scratch-safety check compare against it.
    pub repo_root: PathBuf,
}

// ---------------------------------------------------------------------------
// Pass 1: the Arch provider pass (untagged packages/stable)
// ---------------------------------------------------------------------------

/// The Arch provider pass over one recipe: `pacman -Si` candidates (pkgbase
/// first, then every split pkgname), the never-downgrade pkgrel policy, the
/// transactional rewrite, and — when a source moved — RULE-18 anchoring
/// against the official packaging repo. Returns rc-contract data; the recipe
/// is left rewritten and UNCOMMITTED on success, byte-identical on every
/// failure path.
pub fn sync_arch(
    recipe_dir: &Path,
    provider: &dyn VersionProvider,
    policy: &SyncPolicy,
) -> SyncReport {
    let pkg = recipe_dir
        .file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_default();

    // Physical placement gate (the fish reference gates on
    // $SCRIPT_DIR/packages/stable/*): the Arch repo is the version authority
    // for untagged stable recipes only. Kept in the module — fail-safe — even
    // though the CLI filters too.
    let stable_root = policy.repo_root.join("packages").join("stable");
    if !recipe_dir.starts_with(&stable_root) {
        return SyncReport::nochange(pkg, NoChangeReason::NotStableStaged);
    }

    // pkgver()-driven PKGBUILDs have NO stable pkgver= line — inserting one
    // would OVERRIDE pkgver() and pin the version to the repo release,
    // defeating dev tracking. Skip them.
    if pkgbuild_pkgver_rhs(recipe_dir).is_none() {
        return SyncReport::nochange(pkg, NoChangeReason::PkgverFunction);
    }

    let pkgnames = match pkgbuild_array_checked(recipe_dir, "pkgname") {
        Ok(n) => n,
        Err(e) => {
            return SyncReport {
                pkg,
                outcome: SyncOutcome::Refused {
                    class: RefusalClass::EvalFailure,
                    message: format!(
                        "cannot evaluate the pkgname array of {}/PKGBUILD — {e}; the recipe is named here instead of being version-synced blind",
                        recipe_dir.display()
                    ),
                    restored: RestoreStatus::NothingToRestore,
                },
                anchor: None,
                rows: Vec::new(),
                log: Vec::new(),
            };
        }
    };
    let pkgbase = {
        let b = pkgbuild_var(recipe_dir, "pkgbase").unwrap_or_default();
        if !b.is_empty() {
            b
        } else if pkgnames.len() == 1 {
            pkgnames[0].clone()
        } else {
            pkg.clone()
        }
    };
    let mut candidates: Vec<String> = vec![pkgbase.clone()];
    for n in &pkgnames {
        if !candidates.contains(n) {
            candidates.push(n.clone());
        }
    }

    // Query loop: "name unknown" continues to the next candidate; a real
    // query failure aborts as unverified-freshness.
    let mut found: Option<(String, VersionFields)> = None;
    let mut query_failure: Option<String> = None;
    for c in &candidates {
        match provider.query_name(c) {
            Ok(VersionAnswer::Found(v)) => {
                found = Some((c.clone(), v));
                break;
            }
            Ok(VersionAnswer::UnknownName) => continue,
            Ok(VersionAnswer::QueryFailed(m))
            | Err(ProviderError::Invalid(m))
            | Err(ProviderError::ToolMissing(m))
            | Err(ProviderError::Outage(m)) => {
                query_failure = Some(m);
                break;
            }
            Err(ProviderError::Unsupported(m)) => {
                return SyncReport {
                    pkg,
                    outcome: SyncOutcome::Refused {
                        class: RefusalClass::UnsafeVersionText,
                        message: m,
                        restored: RestoreStatus::NothingToRestore,
                    },
                    anchor: None,
                    rows: Vec::new(),
                    log: Vec::new(),
                };
            }
        }
    }
    if let Some(m) = query_failure {
        return SyncReport {
            pkg,
            outcome: SyncOutcome::QueryFailed {
                message: format!(
                    "cannot query the Arch repository version — the committed version's freshness is unverified: {m}"
                ),
            },
            anchor: None,
            rows: Vec::new(),
            log: Vec::new(),
        };
    }
    let Some((repo_name, repo)) = found else {
        return SyncReport::nochange(pkg, NoChangeReason::UnknownInRepos);
    };
    let _ = repo_name;

    // The parsed pieces are about to become PKGBUILD lines; refuse a value the
    // rewrite cannot write safely BEFORE the first write.
    if !repo.validate() {
        return SyncReport {
            pkg,
            outcome: SyncOutcome::Refused {
                class: RefusalClass::UnsafeVersionText,
                message: format!(
                    "refusing to sync from a repository version this rewrite cannot write safely: '{}'",
                    repo.render()
                ),
                restored: RestoreStatus::NothingToRestore,
            },
            anchor: None,
            rows: Vec::new(),
            log: Vec::new(),
        };
    }

    let cur_pkgver = pkgbuild_var(recipe_dir, "pkgver").unwrap_or_default();
    let cur_pkgrel = {
        let r = pkgbuild_var(recipe_dir, "pkgrel").unwrap_or_default();
        if r.is_empty() {
            "1".to_string()
        } else {
            r
        }
    };

    // Never downgrade the content version — repos can game vercmp with an
    // epoch (repo "1:7.1-1" vs local "7.2-1": 7.2 content is newer, keep it).
    // vercmp when present, exact-string fallback otherwise (the fish
    // fallback: inequality reads as "repo is ahead").
    let vercmp_res = match vercmp(&cur_pkgver, &repo.pkgver) {
        Some(v) => v,
        None if cur_pkgver == repo.pkgver => 0,
        None => -1,
    };
    if vercmp_res > 0 {
        return SyncReport::nochange(pkg, NoChangeReason::NeverDowngrade);
    }
    if vercmp_res == 0 {
        if cur_pkgrel == repo.pkgrel {
            return SyncReport::nochange(pkg, NoChangeReason::Current);
        }
        // Only a repo pkgrel actually AHEAD is a sync worth making; a local
        // pkgrel ahead of the repo is a deliberate bump (2026-09-28).
        let pkgrel_cmp = vercmp(&cur_pkgrel, &repo.pkgrel).unwrap_or(0);
        if pkgrel_cmp >= 0 {
            return SyncReport::nochange(pkg, NoChangeReason::LocalPkgrelAhead);
        }
    }

    let pkgver_changed = cur_pkgver != repo.pkgver;
    let sources_before = match pkgbuild_array_checked(recipe_dir, "source") {
        Ok(s) => s.into_iter().map(SourceEntry::new).collect::<Vec<_>>(),
        Err(e) => {
            return SyncReport {
                pkg,
                outcome: SyncOutcome::Refused {
                    class: RefusalClass::EvalFailure,
                    message: format!("cannot evaluate the PKGBUILD source array — {e}"),
                    restored: RestoreStatus::NothingToRestore,
                },
                anchor: None,
                rows: Vec::new(),
                log: Vec::new(),
            };
        }
    };

    let mut tx = match RecipeTransaction::begin(recipe_dir, &policy.repo_root) {
        Ok(t) => t,
        Err(e) => {
            return SyncReport {
                pkg,
                outcome: SyncOutcome::Refused {
                    class: RefusalClass::RollbackUnsafe,
                    message: format!(
                        "{}; the version sync cannot be made rollback-safe",
                        e.message
                    ),
                    restored: RestoreStatus::NothingToRestore,
                },
                anchor: None,
                rows: Vec::new(),
                log: Vec::new(),
            };
        }
    };

    let staged = match tx.stage() {
        Ok(s) => s,
        Err(e) => {
            let restored = tx.restore();
            return SyncReport {
                pkg,
                outcome: SyncOutcome::Refused {
                    class: RefusalClass::WriteFailed,
                    message: e.message,
                    restored,
                },
                anchor: None,
                rows: Vec::new(),
                log: Vec::new(),
            };
        }
    };
    if let Err(e) = apply_pkgver_version(&staged, recipe_dir, &repo.pkgver) {
        tx.discard_staged();
        return SyncReport {
            pkg,
            outcome: match e {
                PkgverPlanError::WriteFailed => SyncOutcome::Refused {
                    class: RefusalClass::WriteFailed,
                    message: "could not update pkgver".into(),
                    restored: RestoreStatus::NothingToRestore,
                },
                other => SyncOutcome::Unsupported {
                    message: other.to_string(),
                    class: other,
                    restored: RestoreStatus::NothingToRestore,
                },
            },
            anchor: None,
            rows: Vec::new(),
            log: Vec::new(),
        };
    }
    if let Err(e) = apply_release_metadata(&staged, &repo.pkgrel, &repo.epoch) {
        tx.discard_staged();
        return SyncReport {
            pkg,
            outcome: SyncOutcome::Refused {
                class: RefusalClass::WriteFailed,
                message: format!("could not update pkgrel/epoch: {e}"),
                restored: RestoreStatus::NothingToRestore,
            },
            anchor: None,
            rows: Vec::new(),
            log: Vec::new(),
        };
    }
    if let Err(e) = tx.publish() {
        let restored = tx.restore();
        return SyncReport {
            pkg,
            outcome: SyncOutcome::Refused {
                class: RefusalClass::WriteFailed,
                message: e.message,
                restored,
            },
            anchor: None,
            rows: Vec::new(),
            log: Vec::new(),
        };
    }

    // Clear stale source/build artifacts left over from the previous version.
    if let Err(e) = clear_build_artifacts(recipe_dir) {
        let restored = tx.restore();
        return SyncReport {
            pkg,
            outcome: SyncOutcome::Refused {
                class: RefusalClass::WriteFailed,
                message: format!(
                    "could not clear stale build artifacts after the version sync; {e}"
                ),
                restored,
            },
            anchor: None,
            rows: Vec::new(),
            log: Vec::new(),
        };
    }

    let sources_after = match pkgbuild_array_checked(recipe_dir, "source") {
        Ok(s) => s.into_iter().map(SourceEntry::new).collect::<Vec<_>>(),
        Err(e) => {
            let restored = tx.restore();
            return SyncReport {
                pkg,
                outcome: SyncOutcome::Refused {
                    class: RefusalClass::EvalFailure,
                    message: format!("cannot evaluate the rewritten PKGBUILD source array; {e}"),
                    restored,
                },
                anchor: None,
                rows: Vec::new(),
                log: Vec::new(),
            };
        }
    };
    let moved_sources = diff_sources(&sources_before, &sources_after);

    let old = format!("{cur_pkgver}-{cur_pkgrel}");
    let new = format!("{}-{}", repo.pkgver, repo.pkgrel);
    let mut log = Vec::new();

    let (anchor, rows) = if moved_sources.is_empty() {
        // The committed sums still verify (the 26-of-28 literal-version
        // shape) but the committed .SRCINFO is stale truth the moment pkgver
        // moves — refresh it here.
        let srcinfo = refresh_package_srcinfo(recipe_dir);
        (
            None,
            vec![DispositionRow::VersionSynced {
                pkg: pkgbase.clone(),
                old: old.clone(),
                new: new.clone(),
                provider: provider.label(),
                srcinfo,
            }],
        )
    } else {
        let info = match RecipeInfo::read(recipe_dir) {
            Ok(i) => i,
            Err(e) => {
                let restored = tx.restore();
                return SyncReport {
                    pkg,
                    outcome: SyncOutcome::Refused {
                        class: RefusalClass::EvalFailure,
                        message: format!(
                            "cannot read the rewritten recipe for checksum anchoring; {e}"
                        ),
                        restored,
                    },
                    anchor: None,
                    rows: Vec::new(),
                    log,
                };
            }
        };
        let owner = provider.anchor_owner_label();
        let a = anchor_sums(&mut tx, &info, provider, &repo, &moved_sources, &owner);
        let anchor_restored = a.restored();
        match &a {
            AnchorOutcome::Anchored {
                anchored,
                refresh_only,
                published,
                pkgver,
                srcinfo,
            } => {
                log.extend(a.log_lines(&pkgbase, &owner));
                let rows = vec![
                    DispositionRow::VersionSynced {
                        pkg: pkgbase.clone(),
                        old: old.clone(),
                        new: new.clone(),
                        provider: provider.label(),
                        srcinfo: SrcinfoRefresh::Refreshed,
                    },
                    DispositionRow::ChecksumsRefreshed {
                        pkg: pkgbase.clone(),
                        ver: pkgver.clone(),
                        anchored: *anchored,
                        provider: format!("{owner} {published}"),
                        refresh_only: refresh_only.len(),
                        srcinfo: srcinfo.clone(),
                    },
                ];
                (Some(a), rows)
            }
            AnchorOutcome::RefreshOnly {
                files,
                published,
                pkgver,
                srcinfo,
            } => {
                log.extend(a.log_lines(&pkgbase, &owner));
                let rows = vec![
                    DispositionRow::VersionSynced {
                        pkg: pkgbase.clone(),
                        old: old.clone(),
                        new: new.clone(),
                        provider: provider.label(),
                        srcinfo: SrcinfoRefresh::Refreshed,
                    },
                    DispositionRow::ChecksumsRefreshed {
                        pkg: pkgbase.clone(),
                        ver: pkgver.clone(),
                        anchored: 0,
                        provider: format!("{owner} {published}"),
                        refresh_only: files.len(),
                        srcinfo: srcinfo.clone(),
                    },
                ];
                (Some(a), rows)
            }
            AnchorOutcome::Defer {
                reason, message, ..
            } => {
                log.extend(a.log_lines(&pkgbase, &owner));
                return SyncReport {
                    pkg,
                    outcome: SyncOutcome::Deferred {
                        reason: *reason,
                        message: message.clone(),
                        restored: anchor_restored.clone(),
                    },
                    anchor: Some(a),
                    rows: Vec::new(),
                    log,
                };
            }
            AnchorOutcome::IntegrityStop {
                file, want, got, ..
            } => {
                log.extend(a.log_lines(&pkgbase, &owner));
                return SyncReport {
                    pkg,
                    outcome: SyncOutcome::Refused {
                        class: RefusalClass::IntegrityStop,
                        message: format!(
                            "refusing to build — a source does not match the official Arch checksum: {file}: the published value is {want}, the fetched source hashes to {got}"
                        ),
                        restored: anchor_restored.clone(),
                    },
                    anchor: Some(a),
                    rows: Vec::new(),
                    log,
                };
            }
            AnchorOutcome::Refused { message, .. } => {
                log.extend(a.log_lines(&pkgbase, &owner));
                return SyncReport {
                    pkg,
                    outcome: SyncOutcome::Refused {
                        class: RefusalClass::IntegrityStop,
                        message: message.clone(),
                        restored: anchor_restored.clone(),
                    },
                    anchor: Some(a),
                    rows: Vec::new(),
                    log,
                };
            }
            AnchorOutcome::NothingToDo => (None, Vec::new()),
        }
    };

    tx.keep();
    SyncReport {
        pkg,
        outcome: if pkgver_changed {
            SyncOutcome::VersionMoved {
                old,
                new,
                moved_sources: moved_sources.iter().map(|e| e.0.clone()).collect(),
            }
        } else {
            SyncOutcome::ReleaseMoved { old, new }
        },
        anchor,
        rows,
        log,
    }
}

// ---------------------------------------------------------------------------
// Pass 2: the opted-in nvchecker path (AUR / GitHub / …)
// ---------------------------------------------------------------------------

/// The opted-in provider pass over one recipe. **Authorization is the
/// caller's**: this pass must only run for a record carrying the validated
/// `version-sync=nvchecker` topology tag — a `.nvchecker.toml` file alone is
/// REPORT-ONLY and never authorizes a query or a rewrite (`docs/MEMORY.md`
/// rule 18, 2026-10-01).
///
/// Policy in the shape of the fish reference: GitHub resets `pkgrel` to 1
/// only when `pkgver` moves (a local pkgrel is retained at parity); AUR takes
/// `pkgrel`/`epoch` from the matching `.SRCINFO` on a new version and, at
/// equal pkgver, an upstream pkgrel may move forward but never lowers a local
/// revision; anything else keeps the local release metadata. A provider
/// outage or an AUR metadata race defers and restores — never inventing a
/// version.
pub fn sync_nvchecker(
    recipe_dir: &Path,
    provider: &dyn VersionProvider,
    policy: &SyncPolicy,
) -> SyncReport {
    let pkg = recipe_dir
        .file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_default();

    let mut tx = match RecipeTransaction::begin(recipe_dir, &policy.repo_root) {
        Ok(t) => t,
        Err(e) => {
            return SyncReport {
                pkg,
                outcome: SyncOutcome::Refused {
                    class: RefusalClass::RollbackUnsafe,
                    message: format!("{}; version sync cannot be made rollback-safe", e.message),
                    restored: RestoreStatus::NothingToRestore,
                },
                anchor: None,
                rows: Vec::new(),
                log: Vec::new(),
            };
        }
    };

    let info0 = match RecipeInfo::read(recipe_dir) {
        Ok(i) => i,
        Err(e) => {
            return SyncReport {
                pkg,
                outcome: SyncOutcome::Refused {
                    class: RefusalClass::EvalFailure,
                    message: format!("cannot evaluate the recipe — {e}"),
                    restored: RestoreStatus::NothingToRestore,
                },
                anchor: None,
                rows: Vec::new(),
                log: Vec::new(),
            };
        }
    };
    let pkgbase = info0.pkgbase.clone();

    // A tracker section may be named for the recipe's topology id instead of
    // its pkgbase (pkgbase is flavor-derived for some recipes): pkgbase is
    // tried first, the dir name second.
    let mut keys = vec![pkgbase.clone()];
    if !keys.contains(&pkg) {
        keys.push(pkg.clone());
    }
    let mut resolved: Option<String> = None;
    let mut query_failure: Option<String> = None;
    for k in &keys {
        match provider.query_name(k) {
            Ok(VersionAnswer::Found(v)) => {
                resolved = Some(v.pkgver);
                break;
            }
            Ok(VersionAnswer::UnknownName) => continue,
            Ok(VersionAnswer::QueryFailed(m))
            | Err(ProviderError::Invalid(m))
            | Err(ProviderError::ToolMissing(m))
            | Err(ProviderError::Outage(m)) => {
                query_failure = Some(m);
                break;
            }
            Err(ProviderError::Unsupported(m)) => {
                return SyncReport {
                    pkg,
                    outcome: SyncOutcome::Refused {
                        class: RefusalClass::UnsafeVersionText,
                        message: m,
                        restored: RestoreStatus::NothingToRestore,
                    },
                    anchor: None,
                    rows: Vec::new(),
                    log: Vec::new(),
                };
            }
        }
    }
    let Some(new_pkgver) = resolved else {
        let message = query_failure.unwrap_or_else(|| "no version from the provider".to_string());
        return SyncReport {
            pkg,
            outcome: SyncOutcome::Deferred {
                reason: DeferReason::AnchoringRefused,
                message: format!("nvchecker could not resolve a version ({message})"),
                restored: RestoreStatus::NothingToRestore,
            },
            anchor: None,
            rows: Vec::new(),
            log: Vec::new(),
        };
    };
    if !version_value_ok(VersionField::Pkgver, &new_pkgver) {
        return SyncReport {
            pkg,
            outcome: SyncOutcome::Refused {
                class: RefusalClass::UnsafeVersionText,
                message: format!("refusing unsupported upstream pkgver format '{new_pkgver}'"),
                restored: RestoreStatus::NothingToRestore,
            },
            anchor: None,
            rows: Vec::new(),
            log: Vec::new(),
        };
    }

    // AUR metadata is validated BEFORE the rewrite: a mismatch is a metadata
    // race (defer + restore semantics), never an anchor.
    let aur_meta = if provider.family() == ProviderFamily::Aur {
        match provider.release_metadata(&info0, &new_pkgver) {
            Ok(m) => Some(m),
            Err(ProviderError::Unsupported(m)) => {
                return SyncReport {
                    pkg,
                    outcome: SyncOutcome::Refused {
                        class: RefusalClass::UnsafeVersionText,
                        message: m,
                        restored: RestoreStatus::NothingToRestore,
                    },
                    anchor: None,
                    rows: Vec::new(),
                    log: Vec::new(),
                };
            }
            Err(e) => {
                return SyncReport {
                    pkg,
                    outcome: SyncOutcome::Deferred {
                        reason: DeferReason::AnchoringRefused,
                        message: format!("AUR metadata is unavailable or disagrees ({e})"),
                        restored: RestoreStatus::NothingToRestore,
                    },
                    anchor: None,
                    rows: Vec::new(),
                    log: Vec::new(),
                };
            }
        }
    } else {
        None
    };

    let cur_pkgver = info0.pkgver.clone();
    let cur_pkgrel = info0.pkgrel.clone();
    let cur_epoch = info0.epoch.clone();
    if !version_value_ok(VersionField::Pkgver, &cur_pkgver)
        || !version_value_ok(VersionField::Pkgrel, &cur_pkgrel)
        || !version_value_ok(VersionField::Epoch, &cur_epoch)
    {
        return SyncReport {
            pkg,
            outcome: SyncOutcome::Refused {
                class: RefusalClass::UnsafeVersionText,
                message: "the current PKGBUILD version metadata is invalid".into(),
                restored: RestoreStatus::NothingToRestore,
            },
            anchor: None,
            rows: Vec::new(),
            log: Vec::new(),
        };
    }
    // The nvchecker path cannot compare without vercmp (unlike the Arch
    // path's historical fallback): park instead of guessing an order.
    let Some(version_order) = vercmp(&cur_pkgver, &new_pkgver) else {
        return SyncReport {
            pkg,
            outcome: SyncOutcome::Deferred {
                reason: DeferReason::AnchoringRefused,
                message: "cannot compare versions because vercmp is missing".into(),
                restored: RestoreStatus::NothingToRestore,
            },
            anchor: None,
            rows: Vec::new(),
            log: Vec::new(),
        };
    };
    if version_order > 0 {
        return SyncReport::nochange(pkg, NoChangeReason::NeverDowngrade);
    }

    let mut new_pkgrel = cur_pkgrel.clone();
    let mut new_epoch = cur_epoch.clone();
    match provider.family() {
        ProviderFamily::Aur => {
            let meta = aur_meta.expect("AUR metadata was read above");
            if version_order < 0 {
                new_pkgrel = meta.pkgrel;
                new_epoch = meta.epoch;
            } else {
                // At equal pkgver an upstream pkgrel may move forward but
                // never lowers a local revision.
                if vercmp(&cur_pkgrel, &meta.pkgrel).unwrap_or(0) < 0 {
                    new_pkgrel = meta.pkgrel;
                }
                if vercmp(&cur_epoch, &meta.epoch).unwrap_or(0) < 0 {
                    new_epoch = meta.epoch;
                }
            }
        }
        ProviderFamily::Github => {
            if version_order < 0 {
                new_pkgrel = "1".to_string();
            }
        }
        _ => {}
    }

    if pkgbuild_pkgver_rhs(recipe_dir).is_none()
        || !fs::read_to_string(recipe_dir.join("PKGBUILD"))
            .map(|t| t.lines().any(|l| l.starts_with("pkgrel=")))
            .unwrap_or(false)
    {
        return SyncReport {
            pkg,
            outcome: SyncOutcome::Refused {
                class: RefusalClass::MissingLiteralFields,
                message: "PKGBUILD must define literal pkgver and pkgrel fields for version sync"
                    .into(),
                restored: RestoreStatus::NothingToRestore,
            },
            anchor: None,
            rows: Vec::new(),
            log: Vec::new(),
        };
    }

    let pkgver_changed = cur_pkgver != new_pkgver;
    let metadata_changed = pkgver_changed || cur_pkgrel != new_pkgrel || cur_epoch != new_epoch;
    if !metadata_changed {
        return SyncReport::nochange(pkg, NoChangeReason::MetadataCurrent);
    }

    let staged = match tx.stage() {
        Ok(s) => s,
        Err(e) => {
            let restored = tx.restore();
            return SyncReport {
                pkg,
                outcome: SyncOutcome::Refused {
                    class: RefusalClass::WriteFailed,
                    message: e.message,
                    restored,
                },
                anchor: None,
                rows: Vec::new(),
                log: Vec::new(),
            };
        }
    };
    if let Err(e) = apply_pkgver_version(&staged, recipe_dir, &new_pkgver) {
        tx.discard_staged();
        let restored = tx.restore();
        return SyncReport {
            pkg,
            outcome: match e {
                PkgverPlanError::WriteFailed => SyncOutcome::Refused {
                    class: RefusalClass::WriteFailed,
                    message: "could not update pkgver".into(),
                    restored,
                },
                other => SyncOutcome::Unsupported {
                    message: other.to_string(),
                    class: other,
                    restored,
                },
            },
            anchor: None,
            rows: Vec::new(),
            log: Vec::new(),
        };
    }
    if let Err(e) = apply_release_metadata(&staged, &new_pkgrel, &new_epoch) {
        tx.discard_staged();
        let restored = tx.restore();
        return SyncReport {
            pkg,
            outcome: SyncOutcome::Refused {
                class: RefusalClass::WriteFailed,
                message: format!("could not update pkgrel/epoch: {e}"),
                restored,
            },
            anchor: None,
            rows: Vec::new(),
            log: Vec::new(),
        };
    }
    if let Err(e) = tx.publish() {
        let restored = tx.restore();
        return SyncReport {
            pkg,
            outcome: SyncOutcome::Refused {
                class: RefusalClass::WriteFailed,
                message: e.message,
                restored,
            },
            anchor: None,
            rows: Vec::new(),
            log: Vec::new(),
        };
    }
    if let Err(e) = clear_build_artifacts(recipe_dir) {
        let restored = tx.restore();
        return SyncReport {
            pkg,
            outcome: SyncOutcome::Refused {
                class: RefusalClass::WriteFailed,
                message: format!("could not clear artifacts after version sync; {e}"),
                restored,
            },
            anchor: None,
            rows: Vec::new(),
            log: Vec::new(),
        };
    }

    let sources_after = match pkgbuild_array_checked(recipe_dir, "source") {
        Ok(s) => s.into_iter().map(SourceEntry::new).collect::<Vec<_>>(),
        Err(e) => {
            let restored = tx.restore();
            return SyncReport {
                pkg,
                outcome: SyncOutcome::Refused {
                    class: RefusalClass::EvalFailure,
                    message: format!("resolved pkgver cannot be evaluated by its PKGBUILD; {e}"),
                    restored,
                },
                anchor: None,
                rows: Vec::new(),
                log: Vec::new(),
            };
        }
    };

    // AUR coverage: the recipe must be a SUBSET of the provider's source list
    // before its checksums can anchor anything (2026-10-09 gcc-snapshot).
    let mut coverage_extras: Vec<String> = Vec::new();
    if provider.family() == ProviderFamily::Aur {
        match provider.check_coverage(&RecipeInfo {
            sources: sources_after.clone(),
            ..info0.clone()
        }) {
            Coverage::NotCovered { missing } => {
                let restored = tx.restore();
                return SyncReport {
                    pkg,
                    outcome: SyncOutcome::Deferred {
                        reason: DeferReason::AnchoringRefused,
                        message: format!(
                            "AUR .SRCINFO sources do not cover every source of the rewritten recipe (missing: {})",
                            missing.join(", ")
                        ),
                        restored,
                    },
                    anchor: None,
                    rows: Vec::new(),
                    log: Vec::new(),
                };
            }
            Coverage::Covered { extras } => coverage_extras = extras,
        }
    }

    let moved_sources = diff_sources(&info0.sources, &sources_after);
    let old = {
        let o = format!("{cur_pkgver}-{cur_pkgrel}");
        if cur_epoch != "0" {
            format!("{cur_epoch}:{o}")
        } else {
            o
        }
    };
    let new = {
        let n = format!("{new_pkgver}-{new_pkgrel}");
        if new_epoch != "0" {
            format!("{new_epoch}:{n}")
        } else {
            n
        }
    };
    let mut log = Vec::new();
    if !coverage_extras.is_empty() {
        log.push(format!(
            "  note: the provider .SRCINFO carries {} source(s) this recipe does not build: {}",
            coverage_extras.len(),
            coverage_extras.join(", ")
        ));
    }

    let owner = provider.anchor_owner_label();
    if moved_sources.is_empty() {
        // Metadata-only move: refresh the committed .SRCINFO and witness it.
        let srcinfo = refresh_package_srcinfo(recipe_dir);
        let rows = vec![DispositionRow::VersionSynced {
            pkg: pkgbase.clone(),
            old: old.clone(),
            new: new.clone(),
            provider: provider.label(),
            srcinfo,
        }];
        tx.keep();
        return SyncReport {
            pkg,
            outcome: if pkgver_changed {
                SyncOutcome::VersionMoved {
                    old,
                    new,
                    moved_sources: Vec::new(),
                }
            } else {
                SyncOutcome::ReleaseMoved { old, new }
            },
            anchor: None,
            rows,
            log,
        };
    }

    let info = match RecipeInfo::read(recipe_dir) {
        Ok(i) => i,
        Err(e) => {
            let restored = tx.restore();
            return SyncReport {
                pkg,
                outcome: SyncOutcome::Refused {
                    class: RefusalClass::EvalFailure,
                    message: format!("cannot read the rewritten recipe for anchoring; {e}"),
                    restored,
                },
                anchor: None,
                rows: Vec::new(),
                log,
            };
        }
    };
    let version = VersionFields {
        epoch: new_epoch.clone(),
        pkgver: new_pkgver.clone(),
        pkgrel: new_pkgrel.clone(),
    };
    let a = anchor_sums(&mut tx, &info, provider, &version, &moved_sources, &owner);
    let anchor_restored = a.restored();

    let finish =
        |rows: Vec<DispositionRow>, log: Vec<String>, anchor: Option<AnchorOutcome>| SyncReport {
            pkg: pkg.clone(),
            outcome: if pkgver_changed {
                SyncOutcome::VersionMoved {
                    old: old.clone(),
                    new: new.clone(),
                    moved_sources: moved_sources.iter().map(|e| e.0.clone()).collect(),
                }
            } else {
                SyncOutcome::ReleaseMoved {
                    old: old.clone(),
                    new: new.clone(),
                }
            },
            anchor,
            rows,
            log,
        };

    match &a {
        AnchorOutcome::Anchored {
            anchored,
            refresh_only,
            published,
            pkgver,
            srcinfo,
        } => {
            log.extend(a.log_lines(&pkgbase, &owner));
            let rows = vec![
                DispositionRow::VersionSynced {
                    pkg: pkgbase.clone(),
                    old: old.clone(),
                    new: new.clone(),
                    provider: provider.label(),
                    srcinfo: SrcinfoRefresh::Refreshed,
                },
                DispositionRow::ChecksumsRefreshed {
                    pkg: pkgbase.clone(),
                    ver: pkgver.clone(),
                    anchored: *anchored,
                    provider: format!("{owner} {published}"),
                    refresh_only: refresh_only.len(),
                    srcinfo: srcinfo.clone(),
                },
            ];
            tx.keep();
            finish(rows, log, Some(a))
        }
        AnchorOutcome::RefreshOnly {
            files,
            published,
            pkgver,
            srcinfo,
        } => {
            log.extend(a.log_lines(&pkgbase, &owner));
            let rows = vec![
                DispositionRow::VersionSynced {
                    pkg: pkgbase.clone(),
                    old: old.clone(),
                    new: new.clone(),
                    provider: provider.label(),
                    srcinfo: SrcinfoRefresh::Refreshed,
                },
                DispositionRow::ChecksumsRefreshed {
                    pkg: pkgbase.clone(),
                    ver: pkgver.clone(),
                    anchored: 0,
                    provider: format!("{owner} {published}"),
                    refresh_only: files.len(),
                    srcinfo: srcinfo.clone(),
                },
            ];
            tx.keep();
            finish(rows, log, Some(a))
        }
        AnchorOutcome::Defer {
            reason, message, ..
        } => {
            log.extend(a.log_lines(&pkgbase, &owner));
            let out = SyncReport {
                pkg,
                outcome: SyncOutcome::Deferred {
                    reason: *reason,
                    message: message.clone(),
                    restored: anchor_restored.clone(),
                },
                anchor: Some(a),
                rows: Vec::new(),
                log,
            };
            out
        }
        AnchorOutcome::IntegrityStop {
            file, want, got, ..
        } => {
            log.extend(a.log_lines(&pkgbase, &owner));
            SyncReport {
                pkg,
                outcome: SyncOutcome::Refused {
                    class: RefusalClass::IntegrityStop,
                    message: format!(
                        "a source does not match the published checksum: {file}: want {want}, got {got}"
                    ),
                    restored: anchor_restored.clone(),
                },
                anchor: Some(a),
                rows: Vec::new(),
                log,
            }
        }
        AnchorOutcome::Refused { message, .. } => {
            log.extend(a.log_lines(&pkgbase, &owner));
            SyncReport {
                pkg,
                outcome: SyncOutcome::Refused {
                    class: RefusalClass::IntegrityStop,
                    message: message.clone(),
                    restored: anchor_restored.clone(),
                },
                anchor: Some(a),
                rows: Vec::new(),
                log,
            }
        }
        AnchorOutcome::NothingToDo => {
            tx.keep();
            finish(Vec::new(), log, None)
        }
    }
}

/// Clear stale source/build artifacts after a version rewrite. Failure rolls
/// the recipe back — a leftover `src/` from the previous version would be
/// silently reused.
fn clear_build_artifacts(recipe_dir: &Path) -> std::io::Result<()> {
    for dir in ["src", "pkg", "build"] {
        let p = recipe_dir.join(dir);
        match fs::remove_dir_all(&p) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(e),
        }
    }
    Ok(())
}

/// Positional diff of the expanded `source=()` arrays around the rewrite —
/// staleness is a MOVED SOURCE, not a moved version (26 of the 28 stable
/// recipes pin the version inside their URLs, so nothing moves and the
/// committed sums stay valid). Returns the post-rewrite entries that differ.
fn diff_sources(before: &[SourceEntry], after: &[SourceEntry]) -> Vec<SourceEntry> {
    let count = before.len().max(after.len());
    let mut moved = Vec::new();
    for i in 0..count {
        let b = before.get(i);
        let a = after.get(i);
        if b != a {
            if let Some(a) = a {
                if !a.0.is_empty() {
                    moved.push(a.clone());
                }
            }
        }
    }
    moved
}
