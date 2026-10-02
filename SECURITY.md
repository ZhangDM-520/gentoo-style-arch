# Security model

This project is a package-building workspace, not a sandbox. A `PKGBUILD`
contains shell functions that may execute arbitrary commands, download remote
content, run build hooks, and install files. Review changes before running
them, especially when the source or maintainer is unfamiliar.

## Safe operation

- Prefer an unprivileged build. Use `sudo fish build-all.fish ...` only when
  the documented root-supervisor behavior is needed for long install runs.
- `--install` invokes `pacman -U`; inspect the selected package list first and
  keep the system package database backed up.
- The builder reads PKGBUILD scalar and array metadata by sourcing the recipe
  in Bash subprocesses. `--installall` may evaluate top-level code from each
  recipe with an existing package archive while discovering eligible
  `pkgver-pkgrel` outputs; this is not a sandbox and does not run only
  declarative assignments.
- The builder serializes its own pacman transactions but never deletes
  `/var/lib/pacman/db.lck`. Investigate the owning process or stale lock
  manually.
- PGP key IDs and checksums remain in recipes; downloaded key files and
  signatures are not committed. Verify keys through a trusted Arch keyring or
  an independently verified key source.
- Keep `GSA_STATE_DIR` and any build cache private if they contain logs,
  command lines, credentials, or proprietary source paths.
- Do not commit encrypted CI files, tokens, private keys, `.env` files, or
  generated profiles. Rotate a credential immediately if it was exposed.

Report a suspected secret, malicious recipe change, unsafe install behavior,
or source-integrity issue privately to the project maintainers rather than
opening a public issue with the sensitive material.
