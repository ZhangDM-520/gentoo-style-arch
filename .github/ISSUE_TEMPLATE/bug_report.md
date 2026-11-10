---
name: Bug report
about: The engine did something wrong — a plan, a refusal, an exit code, a record
title: ''
labels: ''
assignees: ''
---

<!-- A guide, not a form to satisfy. Delete any heading that does not apply. -->

## Which half is it?

- [ ] The engine (`crates/`, `tests/`, `tools/` — this repository)
- [ ] The recipes, topology or build order (`ZhangDM-520/gsa-recipe`)
- [ ] Not sure — here is what I ran and what came out

Recipes are not authoritative here; if the bug is a `PKGBUILD` or a
`config/topology.conf` record, the other repository owns it. If the engine did
the wrong thing *because* of a recipe, say so — that is an engine bug.

## What did you run, and what happened?

```
$ gsa ...
```

Expected:

Actual (paste the run record's `format: 2` block when there is one — it is
the assertion surface, and prose alone cannot be re-checked):

```
--- run record begin ---
...
--- run record end ---
```

## Version and environment

```
gsa --version            # or: pacman -Q gsa-pm
uname -r
pacman -Qm | head        # only if a house package is involved
```

## Anything that changes engine behaviour underneath it

`GSA_*` inputs you set, a `/etc/gsa` or `~/.config/gsa` edit, a `project` key
pointing at a checkout, `--build-dir`/`--state-dir`, a compiler or makepkg
change. `gsa --help` lists the input roster; check there rather than guessing
at a name.

<!-- Do not paste credentials, tokens, private source URLs or anything from a
     machine you do not own. Redact build-path prefixes if they matter. -->
