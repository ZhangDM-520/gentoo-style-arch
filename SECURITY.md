# Security model

This project is a package-building workspace, not a sandbox. A `PKGBUILD` is
executable shell code running with makepkg's privileges and network access: it
may download remote content, run build hooks, and install files. Review every
recipe change before building it, especially when the source or maintainer is
unfamiliar — even metadata discovery can evaluate top-level recipe code.

## Trust boundaries

- Privilege is pacman-shaped: reads (`-Q*`, listings, `--dry-run`, `-Ma`) run
  as any user; mutations (`-S`, `-B`, `-U`, and the mutating `-M` verbs)
  require root: `sudo gsa …`. Under root the engine and pacman run as root
  while the makepkg family and recipe code are dropped to the build user
  (`SUDO_UID`/`SUDO_GID`) via `setpriv` — makepkg never runs as root.
  `gsa -Mm` is the one inverse: build-user-only, refused as root.
- Nothing prompts. The engine escalates with `sudo -n` only and refuses to
  start an install run that cannot succeed non-interactively;
  confirmation-gated verbs (`-Mm`, `-Mccc`) print their target rows and stop
  unless `--noconfirm` is given.
- The engine never weakens source verification: `--skippgpcheck`,
  `--skipchecksums` and `--skipinteg` are rejected everywhere in `gsa`.
  Checksums and `#signed`/`validpgpkeys` stay in recipes; verify signing keys
  against the maintainer's published key (`CONTRIBUTING.md`).
- Install runs execute `pacman -U`: inspect the plan first (`gsa --dry-run`,
  `gsa -Sl …`) and keep the system package database backed up. The engine
  serializes its own transactions but never deletes `/var/lib/pacman/db.lck`;
  investigate the owning process or a stale lock manually.

## Never commit

Upstream source clones and trees, release archives, downloaded signatures,
PGP key caches, build/staging output, generated profiles, host logs, and
credentials — tokens, private keys, `.env` files, encrypted CI files. Recipe
checksums and key fingerprints stay; downloaded key material does not. Keep
the state root and the build cache private if they contain logs, command
lines, credentials, or proprietary source paths. Rotate a credential
immediately if it was exposed.

## Reporting

Report a suspected secret, malicious recipe change, unsafe install behavior,
or source-integrity issue privately to the project maintainers rather than
opening a public issue with the sensitive material.
