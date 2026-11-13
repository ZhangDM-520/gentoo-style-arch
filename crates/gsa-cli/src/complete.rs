//! Shell completion (contract §D.1): the `--complete` answer and the
//! `--print-completion` wrappers.
//!
//! The grammar lives in `args` (`FLAGS`, `ACTIONS`, `Family`), the names live
//! in the topology, and this module only maps a position to candidates. The
//! three wrapper texts are constants here for the same reason the makepkg
//! bodies are: a shipped file that restates the grammar could drift from the
//! binary, so the wrapper asks the binary instead.
//!
//! Protocol (the wrappers depend on every clause):
//!
//! * argv after `gsa`; the LAST word is the partial token and may be empty;
//! * stdout: `value<TAB>description` per candidate, or the single line
//!   `#mode files` to hand a path position back to the shell;
//! * rc 0 always, and silence on every failure — completion is advisory, so
//!   the fail-closed read discipline (rule 71) deliberately does not apply:
//!   nothing here decides anything. See `docs/gsa-contract.md` §D.1.

use std::io::Write;

use crate::args::{flag_spec, Family, ACTIONS, FLAGS};

/// One completion position's answer.
#[derive(Debug, PartialEq, Eq)]
pub enum Answer {
    Values(Vec<(String, String)>),
    /// A path position: the shell completes a file, not a word from us.
    Files,
}

/// The names completion needs, loaded only when the position asks for them
/// (a flag or a family answer costs no store read).
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Names {
    pub ids: Vec<String>,
    pub sets: Vec<String>,
}

impl Names {
    fn complete(&self, partial: &str, out: &mut Vec<(String, String)>, namespace: bool) {
        for id in &self.ids {
            if id.starts_with(partial) {
                out.push((id.clone(), String::new()));
            }
        }
        if namespace {
            for set in &self.sets {
                let token = format!("@{set}");
                if token.starts_with(partial) {
                    out.push((token, format!("set {set}")));
                }
            }
        }
    }
}

/// The families, in contract order, with their `--help` one-liners.
fn families() -> Vec<(String, String)> {
    let described = |family: Family| match family {
        Family::Q => "query the installed database and the side-car",
        Family::S => "build + install the selection",
        Family::B => "build only: archives to the build cache",
        Family::U => "install from archives: nothing is built",
        Family::M => "maintain engine state",
    };
    Family::ALL
        .into_iter()
        .map(|family| (family.as_str().to_string(), described(family).to_string()))
        .chain([
            ("fetch".to_string(), "exactly gsa -Sw".to_string()),
            ("--help".to_string(), "the spelling roster".to_string()),
        ])
        .collect()
}

/// The first family named by the words (a cluster may carry letters).
fn family_in(words: &[String]) -> Option<Family> {
    for word in words {
        if word == "fetch" {
            return Some(Family::S);
        }
        if let Some(rest) = word.strip_prefix('-') {
            if let Some(family) = rest
                .chars()
                .next()
                .and_then(|c| Family::ALL.into_iter().find(|f| f.letter() == c))
            {
                return Some(family);
            }
        }
    }
    None
}

/// A flag's value position: the choices the engine will itself accept,
/// read from the vocabulary that owns them (`Toolchain::ALL`,
/// `gsa_topo::INTENSITY_LEVELS`) rather than restated here.
fn value_answer(name: &str, partial: &str) -> Answer {
    match name {
        "toolchain" => Answer::Values(
            gsa_model::toolchain::Toolchain::ALL
                .into_iter()
                .map(|toolchain| toolchain.as_str())
                .filter(|value| value.starts_with(partial))
                .map(|value| (value.to_string(), format!("the {value} makepkg body")))
                .collect(),
        ),
        "intensity" => Answer::Values(
            gsa_topo::INTENSITY_LEVELS
                .into_iter()
                .filter(|value| value.starts_with(partial))
                .map(|value| (value.to_string(), String::new()))
                .collect(),
        ),
        // `auto` is the only derived answer; a value the operator has already
        // typed stays a candidate so TAB never takes it away.
        "lanes" | "jobs" => {
            let mut out: Vec<(String, String)> = Vec::new();
            if "auto".starts_with(partial) {
                out.push(("auto".to_string(), "derive from the CPU budget".to_string()));
            }
            if !partial.is_empty()
                && partial != "auto"
                && partial.chars().all(|c| c.is_ascii_digit())
            {
                out.push((partial.to_string(), "keep the current value".to_string()));
            }
            Answer::Values(out)
        }
        "state-dir" | "build-dir" | "config" => Answer::Files,
        // Numeric or free-form: the operator types it, and inventing a value
        // would suggest something the engine has not agreed to.
        _ => Answer::Values(Vec::new()),
    }
}

/// The cluster tokens a family accepts: `-S<letter>` per action, plus the one
/// two-letter action (`-Syu`).
fn clusters(family: Family) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = ACTIONS
        .iter()
        .filter(|action| {
            action.family == family
                && !(action.family == Family::S && matches!(action.letter, 'i' | 's' | 'g'))
        })
        .map(|action| {
            (
                format!("{}{}", family.as_str(), action.letter),
                action.description.to_string(),
            )
        })
        .collect();
    if family == Family::S {
        out.push((
            "-Syu".to_string(),
            "sync the store first, then build + install the stale set".to_string(),
        ));
    }
    out
}

/// The answer for one position.
///
/// `names` is a closure so a flag position never pays for a store read.
pub fn answer(words: &[String], names: impl FnOnce() -> Names) -> Answer {
    let partial = words.last().map(String::as_str).unwrap_or("");
    let preceding = if words.is_empty() {
        &words[..0]
    } else {
        &words[..words.len() - 1]
    };

    // Everything after `--` belongs to pacman: a path, never a word of ours.
    if preceding.iter().any(|word| word == "--") {
        return Answer::Files;
    }

    // A value position: the previous word is a flag that takes one.
    if let Some(previous) = preceding.last() {
        if !previous.contains('=') {
            if let Some(name) = previous.strip_prefix("--") {
                if let Some(spec) = flag_spec(name) {
                    if spec.takes_value {
                        return value_answer(spec.name, partial);
                    }
                }
            }
        }
    }

    if preceding.is_empty() {
        return Answer::Values(
            families()
                .into_iter()
                .filter(|(value, _)| value.starts_with(partial))
                .collect(),
        );
    }

    let family = family_in(preceding);

    if partial.starts_with('@') {
        let mut out: Vec<(String, String)> = gsa_model::Group::ROSTER
            .into_iter()
            .map(|group| (format!("@{group}"), format!("group {group}")))
            .filter(|(value, _): &(String, String)| value.starts_with(partial))
            .collect();
        names().complete(partial, &mut out, true);
        out.retain(|(value, _)| value.starts_with(partial) && !value.is_empty());
        return Answer::Values(out);
    }

    // `--toolchain=gc`: the value rides in the same token as the flag, so a
    // candidate has to spell the whole token back.
    if let Some(rest) = partial.strip_prefix("--") {
        if let Some((name, value)) = rest.split_once('=') {
            if let Some(spec) = flag_spec(name) {
                if spec.takes_value && family.is_none_or(|f| spec.applies_to(f)) {
                    return match value_answer(spec.name, value) {
                        Answer::Values(list) => Answer::Values(
                            list.into_iter()
                                .map(|(candidate, description)| {
                                    (format!("--{name}={candidate}"), description)
                                })
                                .collect(),
                        ),
                        Answer::Files => Answer::Files,
                    };
                }
            }
        }
    }

    if partial.starts_with('-') {
        let mut out: Vec<(String, String)> = Vec::new();
        if let Some(family) = family {
            out.extend(clusters(family));
        }
        out.extend(
            FLAGS
                .iter()
                .filter(|spec| family.is_none_or(|f| spec.applies_to(f)))
                .map(|spec| (format!("--{}", spec.name), spec.description.to_string())),
        );
        out.push((
            "--".to_string(),
            "forward the rest to pacman verbatim".to_string(),
        ));
        out.retain(|(value, _)| value.starts_with(partial));
        return Answer::Values(out);
    }

    // `-U` takes archives as well as refs: a path-looking word is the shell's.
    if family == Some(Family::U) && partial.contains('/') {
        return Answer::Files;
    }

    let mut out: Vec<(String, String)> = Vec::new();
    names().complete(partial, &mut out, false);
    Answer::Values(out)
}

/// The `--complete` seam: print the answer, always with rc 0.
pub fn run(words: &[String], out: &mut dyn Write) -> i32 {
    match answer(words, load_names) {
        Answer::Files => {
            let _ = writeln!(out, "#mode files");
        }
        Answer::Values(candidates) => {
            for (value, description) in candidates {
                if description.is_empty() {
                    let _ = writeln!(out, "{value}");
                } else {
                    let _ = writeln!(out, "{value}\t{description}");
                }
            }
        }
    }
    0
}

/// The names completion offers, or empty: an unreadable workspace must not
/// turn a TAB into a diagnostic.
fn load_names() -> Names {
    let mut names = Names::default();
    let Some(root) = crate::resolve_root_readonly() else {
        return names;
    };
    if let Ok(project) = crate::load_project(&root) {
        for record in &project.topology.records {
            names.ids.push(record.id.as_str().to_string());
        }
        for set in &project.sets {
            names.sets.push(set.name.clone());
        }
    }
    for (name, _) in crate::select::load_user_sets_at(None).unwrap_or_default() {
        names.sets.push(name);
    }
    names.ids.sort();
    names.ids.dedup();
    names.sets.sort();
    names.sets.dedup();
    names
}

const FISH_WRAPPER: &str = r#"# gsa completion for fish — generated by `gsa --print-completion fish`.
# The grammar is the binary's: this file only forwards the command line.
function __gsa_complete
    set -l words (commandline -opc)
    set -e words[1]
    gsa --complete $words (commandline -ct) 2>/dev/null
end

function __gsa_wants_files
    __gsa_complete | string match -q '#mode files'
end

complete -c gsa -f -a '(__gsa_complete | string match -v \'#mode files\')'
complete -c gsa -n '__gsa_wants_files' -F
"#;

const BASH_WRAPPER: &str = r#"# gsa completion for bash — generated by `gsa --print-completion bash`.
# The grammar is the binary's: this function only forwards the command line.
_gsa() {
    local out line
    out=$(gsa --complete "${COMP_WORDS[@]:1:COMP_CWORD}" 2>/dev/null)
    if [ "$out" = '#mode files' ]; then
        COMPREPLY=()
        compopt -o default 2>/dev/null
        return
    fi
    COMPREPLY=()
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        COMPREPLY+=("${line%%$'\t'*}")
    done <<< "$out"
    compopt -o nospace 2>/dev/null
}
complete -F _gsa gsa
"#;

const ZSH_WRAPPER: &str = r#"#compdef gsa
# gsa completion for zsh — generated by `gsa --print-completion zsh`.
# The grammar is the binary's: this file only forwards the command line.
# Installed as site-functions/_gsa, so compinit autoloads this body as the
# `_gsa` completion function: no `_gsa() { … }` wrapper, and `typeset` rather
# than `local` so the body is also valid when sourced directly.
typeset -a _gsa_candidates _gsa_descriptions
_gsa_out=$(gsa --complete "${(@)words[2,CURRENT]}" 2>/dev/null)
if [[ $_gsa_out == '#mode files' ]]; then
    _files
    return
fi
for _gsa_line in ${(f)_gsa_out}; do
    [[ -z $_gsa_line ]] && continue
    _gsa_candidates+=("${_gsa_line%%$'\t'*}")
    if [[ $_gsa_line == *$'\t'* ]]; then
        _gsa_descriptions+=("${_gsa_line#*$'\t'}")
    else
        _gsa_descriptions+=("${_gsa_line%%$'\t'*}")
    fi
done
(( ${#_gsa_candidates} )) || return 1
compadd -d _gsa_descriptions -- "${_gsa_candidates[@]}"
"#;

/// The `--print-completion` seam: one wrapper's text, or a usage error naming
/// the three it accepts.
pub fn print_wrapper(shell: &str, out: &mut dyn Write, err: &mut dyn Write) -> i32 {
    let text = match shell {
        "fish" => FISH_WRAPPER,
        "bash" => BASH_WRAPPER,
        "zsh" => ZSH_WRAPPER,
        "" => {
            let _ = writeln!(
                err,
                "gsa: --print-completion: missing shell (fish|bash|zsh)"
            );
            return crate::RC_USAGE;
        }
        other => {
            let _ = writeln!(
                err,
                "gsa: --print-completion: unknown shell '{other}' (fish|bash|zsh)"
            );
            return crate::RC_USAGE;
        }
    };
    let _ = write!(out, "{text}");
    0
}

impl Family {
    /// The uppercase letter that opens a cluster: `as_str()` is `-S`, so the
    /// letter is its second character — one spelling, not a fifth match.
    fn letter(self) -> char {
        self.as_str().chars().nth(1).unwrap_or('?')
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    fn no_names() -> Names {
        panic!("this position must not read the workspace")
    }

    fn values(answer: Answer) -> Vec<(String, String)> {
        match answer {
            Answer::Values(list) => list,
            other => panic!("expected values, got {other:?}"),
        }
    }

    fn offered(answer: Answer) -> Vec<String> {
        values(answer).into_iter().map(|(value, _)| value).collect()
    }

    #[test]
    fn the_first_word_offers_the_families() {
        // An empty argv is the position before `gsa`'s name: the wrapper
        // calls the seam with no words and must get every family back.
        assert_eq!(
            offered(answer(&[], no_names)),
            vec!["-Q", "-S", "-B", "-U", "-M", "fetch", "--help"]
        );
        // A prefix narrows without a store read.
        assert_eq!(offered(answer(&words(&["-S"]), no_names)), vec!["-S"]);
    }

    #[test]
    fn a_family_offers_its_clusters_and_its_documented_flags() {
        let list = values(answer(&words(&["-S", "-"]), no_names));
        let spellings: Vec<&str> = list.iter().map(|(value, _)| value.as_str()).collect();
        assert!(spellings.contains(&"-Sl"), "the selection listing letter");
        assert!(spellings.contains(&"-Syu"), "the one two-letter action");
        assert!(spellings.contains(&"--dry-run"), "the roster flags");
        assert!(spellings.contains(&"--toolchain"));
        // Clusters are family-scoped: a -Q letter is not offered on -S.
        assert!(!spellings.contains(&"-Qt"));
        // So are the flags: a maintainer-only modifier is not suggested on a
        // build run, and a build knob is not suggested on a query.
        assert!(!spellings.contains(&"--tail") && !spellings.contains(&"--keep"));
        let query = offered(answer(&words(&["-Q", "-"]), no_names));
        assert!(query.contains(&"--machine".to_string()));
        assert!(
            !query.contains(&"--toolchain".to_string())
                && !query.contains(&"--dry-run".to_string()),
            "a -Q query must not be offered build-run flags: {query:?}"
        );
        assert!(
            list.iter().all(|(_, description)| !description.is_empty()),
            "every candidate in this position carries menu text"
        );
    }

    #[test]
    fn a_value_position_offers_what_the_engine_will_accept() {
        assert_eq!(
            offered(answer(&words(&["-B", "--toolchain", ""]), no_names)),
            vec!["gcc", "clang"]
        );
        // `auto` is a lanes/jobs answer, never an intensity profile: the
        // budget resolver rejects it (gsa-sched/src/budget.rs), so completing
        // it would hand the operator a usage error.
        assert_eq!(
            offered(answer(&words(&["-B", "--intensity", ""]), no_names)),
            gsa_topo::INTENSITY_LEVELS.to_vec()
        );
        assert_eq!(
            offered(answer(&words(&["-B", "--lanes", ""]), no_names)),
            vec!["auto"]
        );
        // A value the operator already typed stays a candidate.
        assert_eq!(
            offered(answer(&words(&["-B", "--lanes", "8"]), no_names)),
            vec!["8"]
        );
        // A free-form value claims nothing rather than guessing.
        assert!(offered(answer(&words(&["-Ml", "--tail", ""]), no_names)).is_empty());
    }

    #[test]
    fn the_namespace_offers_groups_then_sets() {
        let names = Names {
            ids: vec!["zlib-ng-git".to_string()],
            sets: vec!["desktop".to_string()],
        };
        let list = offered(answer(&words(&["-S", "@"]), || names));
        assert!(list.contains(&"@core".to_string()));
        assert!(list.contains(&"@build-tools".to_string()));
        assert!(list.contains(&"@desktop".to_string()));
        assert!(
            !list.contains(&"zlib-ng-git".to_string()),
            "@ is the namespace, not the roster"
        );
    }

    #[test]
    fn a_trailing_dash_dash_hands_the_rest_to_the_shell() {
        assert_eq!(
            answer(&words(&["-U", "--", "a.pkg"]), no_names),
            Answer::Files
        );
        assert_eq!(answer(&words(&["-Ua", "--", ""]), no_names), Answer::Files);
    }

    #[test]
    fn an_archive_path_is_the_shells_business() {
        assert_eq!(
            answer(&words(&["-U", "/var/cache/pkg/"]), no_names),
            Answer::Files
        );
        // A bare ref stays ours.
        let names = Names {
            ids: vec!["mesa-git".to_string()],
            sets: Vec::new(),
        };
        assert_eq!(
            offered(answer(&words(&["-U", "mesa"]), || names)),
            vec!["mesa-git"]
        );
        // A path-valued flag is the shell's too.
        assert_eq!(
            answer(&words(&["-S", "--state-dir", "/v"]), no_names),
            Answer::Files
        );
    }

    #[test]
    fn an_inline_value_completes_the_whole_token() {
        // `--toolchain=gc` is one token: the answer has to spell it back, or
        // the shell replaces the flag with a bare value.
        assert_eq!(
            offered(answer(&words(&["-B", "--toolchain=gc"]), no_names)),
            vec!["--toolchain=gcc"]
        );
        // The same family mask applies to the inline form.
        assert!(offered(answer(&words(&["-Q", "--toolchain=gc"]), no_names)).is_empty());
    }

    #[test]
    fn unknown_text_falls_back_to_the_roster_it_knows() {
        let names = Names {
            ids: vec!["zlib-ng-git".to_string(), "zstd".to_string()],
            sets: Vec::new(),
        };
        assert_eq!(
            offered(answer(&words(&["-Q", "z"]), || names)),
            vec!["zlib-ng-git", "zstd"]
        );
        // A family letter the grammar does not have cannot panic a TAB.
        assert!(offered(answer(&words(&["-Z", "-"]), no_names)).contains(&"--dry-run".to_string()));
    }

    #[test]
    fn descriptions_never_break_the_candidate_line() {
        // The wire is one line per candidate; a tab or a newline in the
        // description would corrupt every wrapper's parse.
        let words_list = words(&["-S", "-"]);
        for (value, description) in values(answer(&words_list, no_names)) {
            assert!(!value.contains('\t') && !value.contains('\n'), "{value}");
            assert!(
                !description.contains('\t') && !description.contains('\n'),
                "{value}: {description}"
            );
        }
    }

    #[test]
    fn the_wrappers_are_grammar_free() {
        // Each wrapper must ask the binary: a static list would be the second
        // grammar the roster rule forbids.
        for wrapper in [FISH_WRAPPER, BASH_WRAPPER, ZSH_WRAPPER] {
            assert!(wrapper.contains("gsa --complete"), "{wrapper}");
            assert!(
                !wrapper.contains("--dry-run") && !wrapper.contains("@core"),
                "a wrapper restates the grammar: {wrapper}"
            );
        }
    }

    #[test]
    fn completion_omits_retired_s_query_clusters() {
        let spellings = offered(answer(&words(&["-S", "-"]), no_names));
        for retired in ["-Si", "-Ss", "-Sg"] {
            assert!(
                !spellings.contains(&retired.to_string()),
                "retired cluster {retired} leaked into completion: {spellings:?}"
            );
        }
    }
}
