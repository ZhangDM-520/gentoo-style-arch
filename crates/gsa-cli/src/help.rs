//! `gsa --help` rendering: structured sections fitted to the terminal width.
//!
//! The old help was one hard-wrapped literal whose hand-typed columns collided
//! with the terminal edge. The CONTENT is data now (sections of prose/entry
//! blocks); the two-column alignment and every line break are computed at
//! render time, so the same text stays readable at any width.
//!
//! Width policy (the human/machine split, owner decision 2026-10-23): on a
//! TTY the help is fitted to the real terminal width; off-TTY it renders at a
//! generous fixed width so capture output (fixtures, scripts) is
//! width-stable — wrapped-at-80 lines would split pinned phrases like
//! `freshness-waived / abi-provider-waived` at arbitrary points.

use std::io::IsTerminal;

/// Non-TTY render width: large enough that authored descriptions land on one
/// line, keeping captured output deterministic.
const CAPTURE_WIDTH: usize = 160;
const MIN_WIDTH: usize = 60;

/// A help section: a lead line (wrapped as prose) and two-column entries —
/// `left` (the spelling) and `right` (its description).
struct Section {
    head: &'static str,
    blocks: &'static [(&'static str, &'static str)],
}

const SECTIONS: &[Section] = &[
    Section {
        head: "\
gsa — native build-and-install orchestrator for the curated recipe set
(contract docs/gsa-contract.md; build (-B), build+install (-S), fetch-only
(-Sw), install-from-archives (-U) and maintain (-M) runs are live)

Usage: gsa <FAMILY>[cluster] [long-modifiers] [targets…] [ranges…] [-- <pacman args…>]

Privilege (contract §B.10, like pacman): -Q and every report/plan verb run
unprivileged; -S/-B/-U and write-side -M verbs require root — rerun with
sudo. Builds always run as your user (makepkg is dropped from the root run),
and a root shell without a build user is refused with guidance.",
        blocks: &[],
    },
    Section {
        head: "Output modes (all families; the default follows the terminal — a capture is a machine):",
        blocks: &[
            ("--machine", "leveled machine lines — `INFO|WARNING|ERROR event k=v …`, direct-action fields (the default when stdout is captured); row vocabularies and the `format: 2` run record are identical in both modes"),
        ],
    },
    Section {
        head: "Families (exactly one per invocation; lowercase letters form the cluster):",
        blocks: &[
            ("-Q", "query the installed database and the side-car (read-only; pacman queries stay pacman)"),
            ("-S", "build + install the selection (each package installed before its consumers compile)"),
            ("-B", "build-only: archives to the build cache (PKGDEST), nothing installed"),
            ("-U", "install from archives: nothing is built"),
            ("-M", "maintain engine state: audit, doctor, IgnorePkg closure, logs, mirrors, prune strengths, sets/world, run history"),
            ("gsa fetch", "exactly gsa -Sw"),
        ],
    },
    Section {
        head: "Command surface — query (-Q …; read-only, unprivileged):",
        blocks: &[
            ("gsa -Q", "list installed packages, with side-car columns (abi-token, built version, binpkg instances) where a side-car row exists"),
            ("gsa -Qi <ref…>", "merged info: pacman fields, the side-car record (abi-token, subscriptions in/out, binpkg instances, VCS baseline), recipe metadata and the topology record"),
            ("gsa -Qs <pattern…>", "search installed names/descriptions (pacman -Qs semantics)"),
            ("gsa -Qg [name…]", "groups/sets and their members (all with counts by default)"),
            ("gsa -Ql <ref…>", "list owned files (pacman -Ql — delegated verbatim)"),
            ("gsa -Qo <path…>", "file owner (pacman -Qo — delegated verbatim)"),
            ("gsa -Qu", "stale set: recipes whose tracked version moved past their newest built instance"),
            ("gsa -Qb [ref…]", "binpkg index rows: the retained built instances the side-car DB records (hash-bound, §J.4)"),
            ("gsa -Qp <archive…>", "archive probe: the archive's .PKGINFO matched against its index row, hash/size agreement reported"),
            ("gsa -Qa <ref…>", "ABI report: derived token, abi-rev= override if any, subscriptions recorded against it"),
            ("gsa -Qr", "revdep report over the installed-ELF index: unresolved DT_NEEDED, preserved-lib survivors, exact-pin leftovers"),
            ("gsa -Qt", "resolved topology records, one per line: id|path|groups|edges|tags (the tooling channel)"),
        ],
    },
    Section {
        head: "Command surface — build + install (-S …):",
        blocks: &[
            ("gsa -S <targets…> [ranges…]", "build the selection and install each package's archives before its consumers compile (install-before-dependents; checked install)"),
            ("gsa -Sf …", "force install: always run pacman -U, no same-version skip"),
            ("gsa -Sc …", "prune strength 1 first (src/pkg/build trees and archives), then build + install"),
            ("gsa -S --dry-run <targets…> [ranges…]", "build-order plan without building"),
            ("gsa -Sl [targets…] [ranges…]", "ordered selection listing with range indices (-Bl same; nothing is built or installed)"),
            ("gsa -Sw <targets…> [ranges…]", "fetch and verify the selection's sources through makepkg --verifysource — no build, no install; verdict rows are advisory (§D)"),
            ("gsa -Sy [targets…] [ranges…]", "version-sync pass only: provider queries, transactional recipe rewrites left UNCOMMITTED (review with 'git diff', then commit), and the run-level disposition block (rule 18 anchoring)"),
            ("gsa -Su [targets…] [ranges…]", "update the stale set (recipes whose tracked version moved past their newest built instance) with NO sync pass — the committed versions build as-is (pacman -Su semantics)"),
            ("gsa -Syu [targets…] [ranges…]", "sync first (-Sy), then build+install the stale set"),
        ],
    },
    Section {
        head: "Command surface — build-only (-B …):",
        blocks: &[
            ("gsa -B <targets…> [ranges…]", "build the selection to archives in the build cache (PKGDEST; nothing is installed, no pacman call)"),
            ("gsa -B --dry-run <targets…> [ranges…]", "the same plan shape for build-only"),
        ],
    },
    Section {
        head: "Command surface — install from archives (-U …; nothing is built):",
        blocks: &[
            ("gsa -U <ref…|archive-path…>", "install the named packages' newest complete archive sets (or the named paths) in ONE pacman -U transaction"),
            ("gsa -Ua", "install every index-complete archive set in the workspace in one transaction (force mode)"),
            ("gsa -Uf", "force: bypass the same-version already-installed skip"),
            ("-- <pacman args…>", "forwarded verbatim to every pacman -U of an install run (-S/-U), e.g. -Ua -- --overwrite '*'"),
        ],
    },
    Section {
        head: "Maintain verbs (contract §B.7; side-car self-healing only — never /usr or /var/lib/pacman):",
        blocks: &[
            ("gsa -Ma", "audit report: legacy paths, package drift, stale runtime artifacts, recipe-contract lints (report-only; exit 0, read the report)"),
            ("gsa -Md [--fix]", "doctor: runtime-state reconciliation report; --fix applies the named side-car repairs"),
            ("gsa -Mi [--prune|--backfill]", "IgnorePkg closure of the target pacman.conf: default reports drift; --prune removes stale entries, --backfill adds missing ones"),
            ("gsa -Ml [--tail <ref>] [--keep N]", "per-package log browse/tail; --keep N is the log-retention prune"),
            ("gsa -Mm", "shared-source mirrors: dedupe VCS clones into canonical mirrors (asks first: prints its targets and stops rc 3 without --noconfirm)"),
            ("gsa -Mc <targets…>", "prune strength 1: src/pkg/build trees and archives of the selection"),
            ("gsa -Mcc", "prune strength 2: every built archive in the workspace plus its VCS-revision sidecar (symlinks are never deleted or followed)"),
            ("gsa -Mccc", "prune strength 3: additionally pulled sources (prints its target list and asks first)"),
            ("gsa -Ms [name…] [--add|--remove <ref…>]", "named sets: list sets and members; user sets are managed in the kv store against config/sets/ (computed sets are not editable)"),
            ("gsa -Mw [--add|--remove <ref…>]", "world: the explicitly wanted set"),
            ("gsa -Mh [--prune] [--show <run-id>]", "run history: list recorded runs and their continuations; --show re-renders one; --prune enforces the bounded retention"),
        ],
    },
    Section {
        head: "Every other spelling answers with a 'deferred to a later phase' usage error (rc 2); nothing is stubbed with fake results.

Selection targets (contract §C; exact lookup only — a typo is never auto-corrected):",
        blocks: &[
            ("recipe id", "mesa-git"),
            ("recipe path", "packages/git/mesa-git"),
            ("case-variant id", "Mesa-Git (matched and announced)"),
            ("pacman pkgname", "zen-browser (split outputs included; announced)"),
            ("group / user set", "@<group> over the computed groups ({groups}), or a named user set @<set> ('gsa -Ms' manages user sets)"),
            ("index ranges", "22..38, 22.., ..15 — 1-based over the -Sl listing of the same selection; a bare range is a usage error"),
            ("standalone PKGBUILD", "a PKGBUILD file path, a directory holding one, or a URL of one: staged into its own one-node workspace and built there — gsa + the recipe, no project clone required (build/install/fetch/maintain runs and their --dry-run plan; never mixed with workspace references, and query/report verbs do not take them yet)"),
        ],
    },
    Section {
        head: "A selection expands to its transitive consumers (the reverse build-order closure); --leaf suppresses the expansion and keeps exactly what you named.

Long modifiers (contract §B.8). A build run accepts:",
        blocks: &[
            ("--dry-run", "build-order plan without building"),
            ("--leaf", "suppress consumer expansion — keep exactly what you named"),
            ("--skip", "skip-if-fresh resume: claim a complete verified-fresh archive set; waiver reasons freshness-waived / abi-provider-waived ride the record rows"),
            ("--skip-built", "claim anything already built — newest complete set at any version, no upstream probes; a recipe commit newer than the set rebuilds"),
            ("--vcs-skip-tolerance N", "the --skip waive threshold, positive integers only; beats GSA_VCS_SKIP_TOLERANCE"),
            ("--no-sync", "build the committed version and sums as-is: no provider query, no anchoring, no rewrite"),
            ("--allow-broken-rustc", "skip the rustc sanity probe — escape hatch for runs that compile no Rust, never a way past a real ABI mismatch"),
            ("--fail-fast", "stop dispatch on the first failure; cone-stop is the default"),
            ("--lanes N|auto", "concurrent build lanes"),
            ("--jobs N|auto", "makepkg jobs per lane"),
            ("--intensity LEVEL", "scheduler intensity profile"),
            ("--state-dir PATH", "the state-root override (§J.3): --state-dir beats GSA_STATE_DIR beats the gsa.conf layers (/etc/gsa.conf and ~/.config/gsa/gsa.conf, user over system) beats /var/lib/gsa"),
            ("--no-prefetch", "opt out of the advisory fetch-ahead"),
            ("--prefetch-ahead N", "fetch-ahead window, default 8"),
        ],
    },
    Section {
        head: "--skip and --skip-built are different claims and cannot combine. The side-car queries (-Qb/-Qp) accept --state-dir PATH.

An install run (-S/-U) additionally accepts:",
        blocks: &[
            ("--config PATH", "the target pacman.conf"),
            ("--no-register-ignorepkg", "skip the dynamic IgnorePkg registration, loudly"),
            ("-- <pacman args…>", "forwarded to every pacman -U"),
        ],
    },
    Section {
        head: "A maintain run (-M) accepts its verb's sub-flags (§B.7): --fix, --prune, --backfill, --tail <ref>, --keep N, --show <run-id>, --add, --remove, --noconfirm (the engine's own confirmations — -Mm/-Mccc — never a pacman question), and (-Mi) --config PATH; --dry-run renders a mutating verb's plan and rows without touching anything.

Deferred (parse and refuse, so the message names them): --quiet, --verbose.

Engine environment inputs:",
        blocks: &[
            ("GSA_CONF", "replaces the auto-read gsa.conf layers (/etc/gsa.conf, ~/.config/gsa/gsa.conf) with exactly one file — fixture and hermetic control"),
            ("GSA_STATE_DIR", "the state root (the --state-dir chain above)"),
            ("GSA_BUILD_DIR", "redirects the build cache (makepkg BUILDDIR/PKGDIR/PKGDEST; default: the build user's ~/.cache/gsa)"),
            ("GSA_RECIPES_DIR", "redirects the canonical recipe store (gsa.conf `recipe_dir`; default: the build user's ~/.local/share/gsa/recipes — never below the state root)"),
            ("GSA_LANES, GSA_JOBS, GSA_INTENSITY", "defaults for the matching long modifiers"),
            ("GSA_CPU_THREADS, GSA_MEMORY_GIB", "budget overrides for the scheduler's parallelism truth"),
            ("GSA_TARGET_CPU", "the target CPU class for recipe selection"),
            ("GSA_VCS_SKIP_TOLERANCE", "the --skip waive threshold (the flag beats it)"),
            ("GSA_BUILD_JOBS", "engine output, never an input"),
        ],
    },
    Section {
        head: "Exit codes (contract §G): 0 success; 1 build failure under --fail-fast; 2 usage error (bad flags, unknown reference with nearest candidates, invalid range, empty selection, malformed config record, deferred spelling); 3 refusal (the run refused to start or aborted at a fail-closed gate); 4 cone-stop run with >=1 failure (the parked cone is in the run record); 5 deferral-only (>=1 deferred/parked row, no failure); 130 interrupted — the full run record (plan, outcomes, continuation) is emitted first.",
        blocks: &[],
    },
];

/// The render width: fitted on a TTY, `CAPTURE_WIDTH` otherwise.
fn width() -> usize {
    if std::io::stdout().is_terminal() {
        terminal_width().unwrap_or(80).max(MIN_WIDTH)
    } else {
        CAPTURE_WIDTH
    }
}

/// Terminal width, fish-precedence chain: `$COLUMNS` (explicit user override),
/// then `tput cols`, then None. A spawn here is fine — help renders once.
fn terminal_width() -> Option<usize> {
    if let Ok(cols) = std::env::var("COLUMNS") {
        if let Ok(n) = cols.trim().parse::<usize>() {
            if n > 0 {
                return Some(n);
            }
        }
    }
    let out = std::process::Command::new("tput").arg("cols").output().ok()?;
    let n = String::from_utf8_lossy(&out.stdout).trim().parse::<usize>().ok()?;
    if n > 0 {
        Some(n)
    } else {
        None
    }
}

/// Greedy word wrap; embedded `\n` are hard breaks. A word longer than the
/// width is never split (it overflows — callers may pass a generous width).
fn wrap_words(text: &str, width: usize) -> Vec<String> {
    let mut lines = Vec::new();
    for hard in text.split('\n') {
        let mut cur = String::new();
        for word in hard.split(' ').filter(|w| !w.is_empty()) {
            if cur.is_empty() {
                cur.push_str(word);
            } else if cur.chars().count() + 1 + word.chars().count() <= width {
                cur.push(' ');
                cur.push_str(word);
            } else {
                lines.push(std::mem::take(&mut cur));
                cur.push_str(word);
            }
        }
        lines.push(cur);
    }
    lines
}

fn render_entry(left: &str, right: &str, leftw: usize, width: usize, out: &mut Vec<String>) {
    let desc_width = width.saturating_sub(leftw + 4).max(24);
    let wrapped = wrap_words(right, desc_width);
    if left.chars().count() > leftw {
        // Long spelling: its own line, description aligned to the column.
        out.push(format!("  {left}"));
        let pad = " ".repeat(leftw + 2);
        for line in wrapped {
            out.push(format!("  {pad}{line}"));
        }
    } else {
        let pad = " ".repeat(leftw - left.chars().count());
        let mut first = true;
        for line in wrapped {
            if first {
                out.push(format!("  {left}{pad}  {line}"));
                first = false;
            } else {
                out.push(format!("  {}{line}", " ".repeat(leftw + 2)));
            }
        }
    }
}

/// Render the full help fitted to the policy width (see [`width`]).
pub fn render() -> String {
    render_at(width())
}

/// The computed group roster (H5: the help names every group that exists —
/// spelled from `gsa_model::Group`'s closed table, the one source, so a
/// roster change can never leave the help stale).
fn group_roster() -> String {
    gsa_model::Group::ROSTER
        .iter()
        .map(|group| format!("@{}", group.as_str()))
        .collect::<Vec<_>>()
        .join(", ")
}

/// Render the full help fitted to `w` — the seam the width pinners use.
pub(crate) fn render_at(w: usize) -> String {
    let mut out: Vec<String> = Vec::new();
    for section in SECTIONS {
        if !out.is_empty() {
            out.push(String::new());
        }
        for line in wrap_words(section.head, w) {
            out.push(line);
        }
        if section.blocks.is_empty() {
            continue;
        }
        let leftw = section
            .blocks
            .iter()
            .map(|(left, _)| left.chars().count())
            .max()
            .unwrap_or(0)
            .min(w / 3);
        for (left, right) in section.blocks {
            let rendered_right;
            let right: &str = if right.contains("{groups}") {
                rendered_right = right.replace("{groups}", &group_roster());
                &rendered_right
            } else {
                right
            };
            render_entry(left, right, leftw, w, &mut out);
        }
    }
    let mut s = out.join("\n");
    s.push('\n');
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The owner's complaint was lines running together: every rendered line
    /// must fit its terminal. Only an unbreakable token may overflow
    /// (`wrap_words` never splits a word) — this pin names it if one does.
    #[test]
    fn help_fits_eighty_and_a_hundred_sixty_columns() {
        for w in [80usize, 160] {
            for line in render_at(w).lines() {
                assert!(
                    line.chars().count() <= w,
                    "{w} cols: line is {} chars: {line:?}",
                    line.chars().count()
                );
            }
        }
    }

    /// Every flag spelling lands intact on a line of its own entry (the
    /// fixture pinners grep these; a wrap mid-spelling would break them),
    /// and the two output modes are documented.
    #[test]
    fn spellings_and_modes_survive_wrapping() {
        for w in [80usize, 160] {
            let rendered = render_at(w);
            for section in SECTIONS {
                for (left, _) in section.blocks {
                    assert!(
                        rendered.lines().any(|line| line.trim_start().starts_with(left)),
                        "{w} cols: '{left}' is missing or wrapped mid-spelling"
                    );
                }
            }
            assert!(
                rendered.contains("--machine") && !rendered.contains("--human"),
                "{w} cols: --machine must be documented and --human retired (H2)"
            );
        }
    }

    /// H5: the help names every computed group. The roster is spelled from
    /// `gsa_model::Group::ROSTER` at render (the one source), so this pin
    /// fails if the `{groups}` placeholder ever leaks into the output.
    #[test]
    fn every_computed_group_is_named_and_the_placeholder_never_leaks() {
        let rendered = render_at(CAPTURE_WIDTH);
        assert!(
            !rendered.contains("{groups}"),
            "the {{groups}} placeholder leaked into the help"
        );
        for group in gsa_model::Group::ROSTER {
            assert!(
                rendered.contains(&format!("@{}", group.as_str())),
                "group '{}' is missing from the help roster",
                group.as_str()
            );
        }
    }

    /// H1: the command surface is grouped by family, in family order, and
    /// each family's entries sit under their own heading (never interleaved).
    #[test]
    fn command_surface_is_grouped_by_family_in_order() {
        let rendered = render_at(CAPTURE_WIDTH);
        let pos = |needle: &str| {
            rendered
                .find(needle)
                .unwrap_or_else(|| panic!("missing from the help: {needle:?}"))
        };
        let query = pos("Command surface — query");
        let build_install = pos("Command surface — build + install");
        let build_only = pos("Command surface — build-only");
        let archives = pos("Command surface — install from archives");
        let maintain = pos("Maintain verbs");
        assert!(query < build_install && build_install < build_only);
        assert!(build_only < archives && archives < maintain);
        assert!(pos("gsa -Qi") > query && pos("gsa -Qi") < build_install);
        assert!(pos("gsa -Syu") > build_install && pos("gsa -Syu") < build_only);
        assert!(pos("gsa -B --dry-run") > build_only && pos("gsa -B --dry-run") < archives);
        assert!(pos("gsa -Ua") > archives && pos("gsa -Ua") < maintain);
    }
}
