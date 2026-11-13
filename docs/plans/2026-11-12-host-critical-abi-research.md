# Research — host-critical ABI swaps and the openssl 4.1.0 remaining swap

Date: 2026-11-12. Author: campaign session (engine repo).
Status: findings + proposals only; no engine change has been made.

Every claim carries the command that re-confirms it and the version it applied
to. Re-check before relying on any of it.

## 1 The problem, stated precisely

The full rebuild refuses at `openssl`, correctly. That refusal is the engine
working. What it does not do is tell an operator *why this one matters more
than the other 33*, or that the resolution belongs to a different tool.

## 2 Facts established (with re-runnable handles)

### 2.1 openssl moves its soname; the archive ships no compat name

| | value |
| --- | --- |
| installed | `openssl 3.6.5-1.1`, provides `libcrypto.so=3-64 libssl.so=3-64` |
| archive | `openssl-4.1.0-1`, provides `libcrypto.so=4-64 libssl.so=4-64` |
| archive contents | `usr/lib/libcrypto.so`, `.so.4`, `libssl.so`, `.so.4` — **no `.so.3`** |

Handles:

```sh
pacman -Qi openssl | grep -E 'Version|Provides'
tar -xOOf <pkgs>/openssl-4.1.0-1-x86_64.pkg.tar.zst .PKGINFO | grep provides
tar -tf   <pkgs>/openssl-4.1.0-1-x86_64.pkg.tar.zst | grep 'usr/lib/libcrypto'
```

Applies to: tree at recipe `43d47e1`, 2026-11-12.

### 2.2 34 installed packages that link `libcrypto.so.3` are OUT-OF-TREE

Out-of-tree = installed but with no `packages/<group>/<id>` recipe in the
recipe workspace, so this campaign can never rebuild it.

Handle (exact, re-runnable):

```sh
for f in /usr/bin/* /usr/lib/*.so.* /usr/lib/*/*.so.*; do
  readelf -d "$f" 2>/dev/null | grep -q 'NEEDED.*libcrypto.so.3' || continue
  pkg=$(pacman -Qoq "$f" 2>/dev/null | head -1); [ -n "$pkg" ] || continue
  ls -d ~/.local/share/gsa/recipes/packages/*/"$pkg" >/dev/null 2>&1 || echo "$pkg"
done | sort -u
```

Result on this host (34 names), of which the host-critical ones are:

| package | what breaks | evidence |
| --- | --- | --- |
| `sudo` | every escalation — `sudoers.so`, `libsudo_util.so.0` link `.so.3` | `readelf -d /usr/lib/sudo/sudoers.so \| grep libcrypto` |
| `cryptsetup` | LUKS unlock — `libcryptsetup.so.12` links `.so.3` | `readelf -d /usr/lib/libcryptsetup.so.12 \| grep libcrypto` |

Others in the set: `adios2 apache arrow aws-c-cal bpf composefs dhcpcd efitools
fio glusterfs` and 18 more.

### 2.3 The build order is NOT defective

Handle: `gsa -Sl | grep -nE 'openssl$|gnutls-git$|curl$'`

Observed: `openssl` at index 18, `gnutls-git` at 92, `curl` at 199 — the
provider precedes its consumers. So "the order is defective" (owner case 1) is
excluded by measurement.

### 2.4 It is NOT a transient in-run window (owner case 2 excluded)

`gsa-abi::rows::abi_refusal_rows` classifies each linked consumer as
`in_tx` (rides this transaction), `in_run` (rebuilt later in this run), or
`uncovered`. An out-of-tree package can never be `in_run`, so for these 34 the
coverage test is structurally false — not a race, not a temporary window.

Handle: `crates/gsa-abi/src/rows.rs` `abi_refusal_rows`, the `linked_consumers`
loop.

### 2.5 The remedy already exists outside the campaign

```sh
pacman -Si openssl | grep -E '^Repository|^Version'
#   core/openssl 4.1.0-1   (cachyos-core-znver4 still ships 3.6.5-1.1)
```

`core` carries 4.1.0, so a distro transaction upgrades openssl **and** its
stock consumers in one atomic `pacman -U` — which is exactly the heal batch
rule 69 demands, and which the engine does not build (rule 69: "`heal-batch-needed`
and staged swaps remain unbuilt").

### 2.6 The bump predates this session

`git log -1 --format=%B 46a3232` in the recipe repo: *"fix(openssl): follow
core's 4.1.0 soname bump…"*, dated 2026-11-11. The campaign did not create it;
the campaign is the first run to attempt it.

### 2.7 llvm-git is NOT a soname move (checked because it was suspected)

```sh
pacman -Qi llvm-libs-git | grep -E 'Version|Provides'   # llvm-libs=<ver>, NOT libLLVM.so=NN
```

`llvm-libs-git` provides `llvm-libs=<pkgver>` — there is no soname provide to
drift, and `/usr/lib/libLLVM.so.24` is unchanged between
`24.0.0_r604528` and `24.0.0_r607209`. Stock `mesa-git` dlopens
`libLLVM.so.24` and keeps resolving. The AGENTS.md black-desktop hazard is a
*major* LLVM bump, not a rebuild inside major 24.

## 3 Proposals (ranked; none implemented)

### P1 `abi-host-critical` refusal class — the core hardening

The gap is classification, not detection. `abi_refusal_rows` already receives
`workspace_names`; it does not distinguish "out-of-tree and inert" from
"out-of-tree and load-bearing". Proposal: a declared list of host-critical
package names, checked in the existing consumer loop, emitting its own refusal
row (`abi-host-critical <archive> <consumer> <soname>`) and message naming the
package and the consequence, instead of one anonymous `abi-soname` line among
34.

- Where: `crates/gsa-abi/src/rows.rs`, beside the `uncovered`/`pinners` classes.
- Input: a new roster (see P4). No new decision seam, no new counter.
- Contract: §E.3's `refuse` reason list gains `abi-host-critical`.

### P2 Name the remedy in the row

The refusal text should say that the provider and its stock consumers move
together in a distro transaction. Static text is wrong (the repository differs
per host); the honest form is a named, actionable sentence plus the consumer
list. Proposal: the message carries `run the distro transaction for <provider>`
and the count, with the full list on the note lines.

### P3 Pre-flight census (read-only)

Before dispatch, report every soname move in the selection whose consumer set
contains an out-of-tree package, host-critical ones flagged. Today the danger
surfaces at the install gate of package 18 — after 17 packages already
installed. A plan-time census moves it to the moment of decision.

- Where: the listing/plan path, not the install gate.
- Constraint: read-only and `-Sl`-safe (it must not run `pacman -U`).

### P4 Where the roster lives

Three candidates, and this is the one open design decision:

| option | shape | trade-off |
| --- | --- | --- |
| (a) engine constant | `gsa-abi::HOST_CRITICAL` array | simple; a distro-agnostic guess hard-coded in a binary |
| (b) recipe-repo config | `config/host-critical.conf`, strict loader like `abi-exclusions.conf` | operator-editable per host; adds a loader + fixture |
| (c) derived from pacman | Essential/base group membership at run time | no roster to rot; but "base" is not "load-bearing" and the query is host-specific |

Recommendation: **(b)**, because the recipe repo already owns policy
(`config/`), already has a strict three-field loader precedent, and the list is
genuinely host-dependent. (a) as the built-in fallback body when the file is
absent — the same two-rung shape `gsa.conf` uses.

### P5 What NOT to do

Do **not** add `libcrypto.so.3` to `config/abi-exclusions.conf`. That registry
is for names that can *never* resolve on this host (a CUDA plugin on an AMD
box). `libcrypto.so.3` resolves fine after the distro transaction, so an entry
there would stand a real gate down permanently and hide the next genuine move.

## 4 Open questions for the owner

1. Is the roster a recipe-repo config file (P4b) or an engine constant (P4a)?
2. Should `abi-host-critical` refuse *harder* than `abi-soname` (e.g. refuse
   the whole run rather than only that subject's cone)? Today all `refuse`
   rows abort before any `pacman` call.
3. Does P3 belong in this campaign or in the follow-up? It is the only proposal
   that changes what an operator sees *before* a run.
4. Who performs the openssl swap: the owner via `pacman -Syu`, or a later
   campaign phase with an explicit heal-batch implementation (rule 69's unbuilt
   gap)?

## 5 Recheck log

| fact | re-checked | command |
| --- | --- | --- |
| 2.1 soname move | 2026-11-12 | §2.1 handles |
| 2.2 34 out-of-tree | 2026-11-12 | §2.2 handle |
| 2.3 order | 2026-11-12 | `gsa -Sl` |
| 2.4 not transient | 2026-11-12 | `rows.rs` read |
| 2.5 core has 4.1.0 | 2026-11-12 | `pacman -Si openssl` |
| 2.6 bump pre-existing | 2026-11-12 | `git log -1 46a3232` |
| 2.7 llvm safe | 2026-11-12 | `pacman -Qi llvm-libs-git` |
