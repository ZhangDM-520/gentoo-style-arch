# Copilot instructions — Gentoo_Style_Arch (engine repository)

This repository's memory is **`AGENTS.md` at the repo root**. It is the single
source of truth: what each half is, the engine/recipe boundary, the read-first
map, commands, the crate split, the rules, the pitfalls, the queue and the
shell-boundary hazards. Read it first, then `docs/JOURNAL.md` for what just
changed.

Nothing is restated here on purpose. A rule, path or command copied into a
second file drifts in one of them — that is the failure this file used to
cause, with roughly thirty kilobytes of guidance that had already gone stale
against the documents it duplicated. Operational detail lives where it is
maintained: `docs/gsa-contract.md` (authoritative interface),
`docs/build-guide.md` (families, selection, inspect/dry-run/build,
installation, environment, troubleshooting), `docs/architecture.md` (crate
split), `docs/portability.md` (intensity profiles), `CONTRIBUTING.md` (change
hygiene, validation, trimming), `SECURITY.md` (trust model).

## Relationship to the host's global instruction

The host loads this file **before** its global agent instruction, so where the
two overlap the global rule is the baseline and `AGENTS.md` is the
repo-specific refinement. Reviewed against the global rules on 2026-10-17: the
shell-boundary hazard (fish login shell vs bash tool-call shells), the
agent-shell git hardening (`GIT_CONFIG_COUNT=0` for bare-repo and makepkg VCS
operations), the concurrency check before a heavy build, the validation
standard, and the never-bypass-checksums-or-signatures rule all appear in
concrete form in `AGENTS.md` and `CONTRIBUTING.md`, and nothing there
contradicts the global instruction.

One global rule is inherited unchanged because this repository has no variant
of it: workspace isolation — canonical edits stay in this repository, scratch
goes to `~/Workspace/`, and fixture scratch stays in the harness's `$TMPDIR`
trees instead. The commit routine also comes from the host's global
instruction; `AGENTS.md`'s protocol paragraph states the operative half
precisely — never commit or push unprompted, because a green battery is
evidence, not consent.

The other half of the system is the **`gsa-recipe`** repository (recipes and
topology). Its memory is that repository's own `AGENTS.md`; nothing about
recipes, `PKGBUILD` policy or the build order is authoritative here.
