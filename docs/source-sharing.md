# Shared source mirrors

`gsa -Mm` (the former `--link-sources` operation) scans the `git+` entries in
every `PKGBUILD`, groups them by effective URL, and points duplicate local
source names at one canonical runtime mirror per URL. Canonical selection
prefers an existing valid mirror, then `packages/core/` paths.

The operation:

- accepts only a real Git working clone or bare mirror as an existing
  canonical source;
- repairs an origin URL or missing fetch refspec when safe;
- replaces a stale empty source directory with the link but never deletes or
  overwrites a populated directory — a populated non-Git directory is
  reported and left alone;
- preserves a missing canonical path as a dangling symlink the first
  canonical build populates (makepkg clones through the link), so a missing
  mirror is valid on a clean checkout;
- never deletes or follows symlinks it did not create.

The verb is confirmation-gated and never prompts: without `--noconfirm` it
prints its target rows and stops (rc 3, `confirmation-required`);
`--dry-run` renders the same rows and mutates nothing.

Mirrors and symlinks are runtime state. They are intentionally absent from a
clean checkout and must never be committed. Run `gsa -Mm` as the build user —
never under a root supervisor; root is refused.
