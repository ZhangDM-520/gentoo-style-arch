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

/// The engine environment INPUT roster (contract §B.8) — the ONE table: it
/// renders in this help AND is what `record::env_required` filters (§H.2),
/// so a variable can never be documented here yet silently vanish from a
/// continuation's `env-required:` line. `GSA_BUILD_JOBS` is engine OUTPUT
/// (exported per lane), deliberately absent.
pub(crate) const ENV_INPUTS: &[(&str, &str)] = &[
    ("GSA_CONF", "use one gsa.conf in place of the system and user files"),
    ("GSA_CONF_DIR", "use one directory for gsa.conf and per-compiler makepkg config"),
    ("GSA_STATE_DIR", "default for --state-dir"),
    ("GSA_BUILD_DIR", "default for --build-dir; also suppresses its prompt"),
    ("GSA_RECIPES_DIR", "redirects the canonical recipe store (gsa.conf `recipe_dir`; default: the build user's ~/.local/share/gsa/recipes — never below the state root)"),
    ("GSA_RECIPE_CHECKOUT", "the recipe repository checkout the real-tree checks read (absolute or ~/… path; unset on an engine-only checkout, where those checks skip loudly)"),
    ("GSA_LANES", "default for --lanes (the flag beats it)"),
    ("GSA_JOBS", "default for --jobs (the flag beats it)"),
    ("GSA_INTENSITY", "default for --intensity (the flag beats it)"),
    ("GSA_CPU_THREADS", "override the scheduler CPU thread count"),
    ("GSA_MEMORY_GIB", "override scheduler memory in GiB"),
    (
        "GSA_TARGET_CPU",
        "CPU tuning passed through to recipes (the engine reads nothing; a resume preserves it)",
    ),
    ("GSA_VCS_SKIP_TOLERANCE", "the --skip waive threshold (the flag beats it)"),
    ("NO_COLOR", "disable colour when non-empty; explicit --color takes precedence"),
    ("CI", "suppress prompts when non-empty and set to a value other than 0 or false"),
];

const SECTIONS: &[Section] = &[
    Section {
        head: "\
gsa builds and installs packages from recipes. See docs/gsa-contract.md.

Usage: gsa <FAMILY>[cluster] [long-modifiers] [targets…] [ranges…] [-- <pacman args…>]

Queries and plans run unprivileged. Writes generally require root. Builds
run as the build user, and -Mm requires the build user (§B.10).",
        blocks: &[],
    },
    Section {
        head: "Output modes (-S/-B/-U/-M):",
        blocks: &[
            ("--machine", "emit LEVEL event k=v lines (INFO, WARNING or ERROR); default for captured stdout"),
            ("-Q*, -Sl, -Ml", "--machine keeps a stable row vocabulary on stdout; -Sl can note a range clamp on stderr"),
        ],
    },
    Section {
        head: "Families (exactly one per invocation; lowercase letters form the cluster):",
        blocks: &[
            ("-Q", "query installed packages and engine state"),
            ("-S", "build + install"),
            ("-B", "build archives"),
            ("-U", "install archives"),
            ("-M", "maintain engine state"),
            ("gsa fetch", "exactly gsa -Sw"),
        ],
    },
    Section {
        head: "Command surface — query (-Q …; read-only, unprivileged):",
        blocks: &[
            ("gsa -Q", "list installed packages with ABI token, built version and archive count when recorded"),
            ("gsa -Qi <ref…>", "show pacman, engine, recipe and topology details"),
            ("gsa -Qs <pattern…>", "search installed names and descriptions"),
            ("gsa -Qg [name…]", "groups/sets and their members (all with counts by default)"),
            ("gsa -Ql <ref…>", "list package files (pacman -Ql)"),
            ("gsa -Qo <path…>", "find the package owning a file (pacman -Qo)"),
            ("gsa -Qu", "stale set: recipes whose tracked version moved past what is installed (or newest built instance if uninstalled)"),
            ("gsa -Qb [ref…]", "list retained archives from the binpkg index"),
            ("gsa -Qp <archive…>", "check package metadata, hash and size against the binpkg index"),
            ("gsa -Qa <ref…>", "ABI report: derived token, abi-rev= override if any, subscriptions recorded against it"),
            ("gsa -Qr", "revdep report over the installed-ELF index: unresolved DT_NEEDED, preserved-lib survivors, exact-pin leftovers"),
            ("gsa -Qt", "print topology rows as id|path|groups|edges|tags"),
        ],
    },
    Section {
        head: "Command surface — build + install (-S …):",
        blocks: &[
            ("gsa -S <targets…> [ranges…]", "build and install each package before its consumers build"),
            ("gsa -Sf …", "force install, bypassing the already-current check"),
            ("gsa -Sc …", "prune build trees and archives, then build + install"),
            ("gsa -S --dry-run <targets…> [ranges…]", "build-order plan without building"),
            ("gsa -Sl [targets…] [ranges…]", "list the selection in build order with range indices (-Bl also works)"),
            ("gsa -Sw <targets…> [ranges…]", "fetch and verify sources only (accepts --state-dir PATH and --toolchain gcc|clang)"),
            ("gsa -Sy [targets…] [ranges…]", "sync versions only, leaving recipe changes uncommitted"),
            ("gsa -Su [targets…] [ranges…]", "build and install stale recipes using committed versions (no sync)"),
            ("gsa -Syu [targets…] [ranges…]", "sync first (-Sy), then build+install the stale set"),
        ],
    },
    Section {
        head: "Command surface — build-only (-B …):",
        blocks: &[
            ("gsa -B <targets…> [ranges…]", "build archives to PKGDEST; workspace dependencies must already be installed"),
            ("gsa -B --dry-run <targets…> [ranges…]", "show the build-only plan"),
        ],
    },
    Section {
        head: "Command surface — install from archives (-U …; nothing is built):",
        blocks: &[
            ("gsa -U <ref…|archive-path…>", "install newest complete archive sets or explicit paths in one transaction"),
            ("gsa -Ua", "install every index-complete archive set in the workspace in one transaction (force mode)"),
            ("gsa -Uf", "force: bypass the same-version already-installed skip"),
            ("gsa -U --leaf <ref…|archive-path…>", "install only named archives; report the ABI wave without expanding it"),
            ("-- <pacman args…>", "forwarded verbatim to every pacman -U of an install run (-S/-U), e.g. -Ua -- --overwrite '*'"),
        ],
    },
    Section {
        head: "Maintain verbs (contract §B.7; side-car self-healing only — never /usr or /var/lib/pacman):",
        blocks: &[
            ("gsa -Ma", "report drift in recipes, packages and runtime state"),
            ("gsa -Md [--fix]", "report runtime-state discrepancies; apply repairs with --fix"),
            ("gsa -Mi [--prune|--backfill]", "report IgnorePkg drift; prune stale entries or backfill missing ones"),
            ("gsa -Ml [--tail <ref>] [--keep N]", "browse, tail or prune package logs"),
            ("gsa -Mm", "deduplicate VCS clones into shared mirrors"),
            ("gsa -Mc <targets…>", "prune selected build trees and archives"),
            ("gsa -Mcc", "prune all workspace archives and their VCS sidecars; leave symlinks intact"),
            ("gsa -Mccc", "also prune downloaded sources"),
            ("gsa -Ms [name…] [--add|--remove <ref…>]", "list sets and edit user-set membership"),
            ("gsa -Mw [--add|--remove <ref…>]", "world: the explicitly wanted set"),
            ("gsa -Mh [--prune] [--show <run-id>]", "list, show or prune run records"),
        ],
    },
    Section {
        head: "Selection targets (contract §C; exact lookup only — a typo is never auto-corrected):",
        blocks: &[
            ("recipe id", "mesa-git"),
            ("recipe path", "packages/git/mesa-git"),
            ("case-variant id", "Mesa-Git (matched and announced)"),
            ("snapshot alias", "<id>-snapshot for a recipe whose primary VCS source is commit-pinned"),
            ("pacman pkgname", "zen-browser (split outputs included; announced)"),
            ("group / user set", "{groups} or @<set> (manage user sets with gsa -Ms)"),
            ("index ranges", "22..38, 22.., ..15 — 1-based over the -Sl listing of the same selection; a bare range is a usage error"),
            ("standalone PKGBUILD", "PKGBUILD path, containing directory or URL; use it alone for build, install, fetch or maintain"),
        ],
    },
    Section {
        head: "Selection includes transitive consumers with installed outputs. -Sl reports skipped consumers.

Long modifiers (contract §B.8). A build run accepts:",
        blocks: &[
            ("--dry-run", "build-order plan without building"),
            ("--leaf", "keep the named selection; report the ABI wave without expanding it"),
            ("--skip", "reuse verified-fresh archives; record freshness-waived / abi-provider-waived when applicable"),
            ("--skip-built", "reuse the newest complete archive set without upstream probes; rebuild after a newer recipe commit"),
            ("--vcs-skip-tolerance N", "the --skip waive threshold, positive integers only; beats GSA_VCS_SKIP_TOLERANCE"),
            ("--no-sync", "build with committed versions and checksums"),
            ("--allow-broken-rustc", "skip the rustc sanity probe — escape hatch for runs that compile no Rust, never a way past a real ABI mismatch"),
            ("--fail-fast", "stop dispatch on the first failure; cone-stop is the default"),
            ("--lanes N|auto", "concurrent build lanes"),
            ("--jobs N|auto", "makepkg jobs per lane"),
            ("--intensity LEVEL", "CPU and memory budget: {intensity}"),
            ("--toolchain gcc|clang", "compiler family; overrides the topology tag and PKGBUILD inference"),
            ("--state-dir PATH", "state root; precedence is flag, GSA_STATE_DIR, gsa.conf, /var/lib/gsa"),
            ("--build-dir PATH", "build cache; precedence is flag, GSA_BUILD_DIR, gsa.conf, ~/.cache/gsa (build user)"),
            ("--no-build-dir-prompt", "resolve the build cache without asking on a terminal"),
            ("--no-prefetch", "opt out of the advisory fetch-ahead"),
            ("--prefetch-ahead N", "fetch-ahead window, default 8"),
            ("--color auto|always|never", "auto colours terminals, always also colours pipes, never disables colour; --machine takes precedence"),
        ],
    },
    Section {
        head: "--skip and --skip-built are different claims and cannot combine. The side-car queries (-Qb/-Qp) accept --state-dir PATH.

Install modifiers (-S and -U, with --with available only for -S):",
        blocks: &[
            (
                "--config PATH",
                "the target pacman.conf — its DBPath is the database every gate reads and the transaction writes",
            ),
            ("--no-register-ignorepkg", "skip the dynamic IgnorePkg registration, loudly"),
            (
                "--with PKG",
                "add a repo package to the -S install step that needs it for ABI compatibility (repeatable or comma-separated)",
            ),
            (
                "-- <pacman args…>",
                "forwarded to every pacman -U; a database rebind (--dbpath/--root/--sysroot/--config) is refused",
            ),
        ],
    },
    Section {
        head: "For -M, --dry-run previews changes and -Mi accepts --config PATH.
-Mcc/-Mccc/-Mm list targets and require --noconfirm on unattended runs.

Deferred (parse and refuse, so the message names them): --quiet, --verbose.

Engine environment inputs (GSA_BUILD_JOBS is engine OUTPUT, exported per lane — never an input):",
        blocks: ENV_INPUTS,
    },
    Section {
        head: "Exit codes (contract §G)
  0 success, 1 fail-fast build failure, 2 usage error, 3 refusal
  4 cone-stop failure, 5 deferral only, 130 interrupted (emits the run record)",
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

/// Terminal width through the ONE probe (`style::terminal_width`): stdout's
/// tty, `$COLUMNS` first. `tput cols` is not consulted — a captured stdout
/// makes it answer its 80-column default even on a 40-column pty.
fn terminal_width() -> Option<usize> {
    crate::style::terminal_width()
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
            } else if right.contains("{intensity}") {
                let roster = gsa_model::INTENSITY_PROFILES
                    .into_iter()
                    .map(|(name, percent)| {
                        let default = if name == gsa_model::DEFAULT_INTENSITY {
                            " (default)"
                        } else {
                            ""
                        };
                        format!("{name} {percent}%{default}")
                    })
                    .collect::<Vec<_>>()
                    .join(", ");
                rendered_right = right.replace("{intensity}", &roster);
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
                        rendered
                            .lines()
                            .any(|line| line.trim_start().starts_with(left)),
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

    /// §B.8/H.2: the environment roster is ONE table — every input renders
    /// in the help AND is what the continuation's `env-required:` filters.
    /// This is the pin that was missing: a variable added to the help but
    /// not to the roster silently under-reported a resume's needs (and vice
    /// versa). `GSA_BUILD_JOBS` is engine output, so it is named in the
    /// section head and must never be a roster row.
    #[test]
    fn every_env_input_in_the_roster_is_rendered_in_the_help() {
        // The roster §B.8 names, verbatim: a row removed from the ONE table
        // silently under-reports a resume's needs, so the set itself is
        // pinned here (the rendered-help half below proves each row prints).
        let expected = [
            "GSA_CONF",
            "GSA_CONF_DIR",
            "GSA_STATE_DIR",
            "GSA_BUILD_DIR",
            "GSA_RECIPES_DIR",
            "GSA_RECIPE_CHECKOUT",
            "GSA_LANES",
            "GSA_JOBS",
            "GSA_INTENSITY",
            "GSA_CPU_THREADS",
            "GSA_MEMORY_GIB",
            "GSA_TARGET_CPU",
            "GSA_VCS_SKIP_TOLERANCE",
            "NO_COLOR",
            "CI",
        ];
        assert_eq!(
            ENV_INPUTS.iter().map(|(name, _)| *name).collect::<Vec<_>>(),
            expected,
            "the engine environment input roster changed"
        );
        let rendered = render_at(CAPTURE_WIDTH);
        for (name, description) in ENV_INPUTS {
            assert!(
                !description.trim().is_empty(),
                "roster row {name} has no description"
            );
            assert!(
                rendered
                    .lines()
                    .any(|line| line.trim_start().starts_with(name)),
                "roster input '{name}' is missing from the rendered help"
            );
        }
        assert!(
            !ENV_INPUTS.iter().any(|(name, _)| *name == "GSA_BUILD_JOBS"),
            "GSA_BUILD_JOBS is engine output, never a roster input"
        );
        assert!(
            rendered.contains("GSA_BUILD_JOBS is engine OUTPUT"),
            "the help must still name GSA_BUILD_JOBS as output"
        );
        // No silent duplicates: one row per variable.
        for (index, (name, _)) in ENV_INPUTS.iter().enumerate() {
            assert!(
                !ENV_INPUTS[..index].iter().any(|(other, _)| other == name),
                "roster input '{name}' is listed twice"
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

    #[test]
    fn help_matches_contract_for_stale_and_confirmations() {
        let rendered = render_at(CAPTURE_WIDTH);
        assert!(
            rendered.contains("-Mcc/-Mccc/-Mm"),
            "confirmations summary missing -Mcc:\n{rendered}"
        );
        assert!(
            rendered.contains("installed") && rendered.contains("-Qu"),
            "-Qu must describe installed-first stale semantics"
        );
    }
}
