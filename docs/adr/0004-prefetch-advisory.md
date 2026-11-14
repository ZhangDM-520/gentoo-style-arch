# Fetch-ahead: advisory prefetch through `makepkg --verifysource`

A flaky upstream at fetch time walls a package at the moment it is needed
(one `curl: (56) unexpected eof` kills the lane, cone-stop drains the run),
even though the same bytes would have served minutes earlier. We decided on
a dispatcher-owned **fetch-ahead**: a bounded lookahead window over the plan
(topological) order that spawns one-shot `--fetch-job` children running
`makepkg --verifysource` — download + checksum + PGP verify into the shared
source cache — while earlier packages compile. `gsa -Sw <targets…>` is the
same pipeline as a first-class fetch-only run. Every fetch verdict is
**advisory for builds**: it warns and logs, and the lane's own makepkg
remains the authoritative gate at build time. Verification is makepkg's and
is never re-implemented or weakened: the fetch argv is exactly
`makepkg --verifysource` with `GIT_CONFIG_COUNT=0` — never `-s`, `-o`,
`--holdver`, `--skipchecksums`, `--skipinteg`, `--skippgpcheck` (the
verification contract, `AGENTS.md` rule 15, is untouched).

## Decisions

- **Verdict vocabulary is its own** (`ok|failed|skipped` + kebab reason:
  `ok`, `retry-ok`, `quarantined-retry-ok`, `verify-failed`, `sig-key-unknown`,
  `sig-key-not-allowed`, `sig-key-untrusted`, `sig-bad`, `sig-error`,
  `fetch-failed`, `eval-failed`, `vcs-only`, `not-a-candidate`, `disk-floor`,
  `result-lost`, `local-source-missing`, `unverified-sums`).
  A fetch outcome is not a lane outcome — `lane_outcome_*` never carries it.
  The typed codec (`v2 <pkg> <verdict> <dur> <reason…>`) is the only way it
  crosses the process boundary (§F.2 discipline).
- **A verification failure reports the STAGE that failed, not one word**
  (2026-11-15, R2-juno-4). `makepkg` runs the checksum stage and the signature
  stage as separate `==>` sections and returns on a checksum failure
  (`/usr/share/makepkg/integrity.sh:42-43`), and its signature line names the
  **payload** (`    <file> ... FAILED (unknown public key <key>)`) — it prints
  `${file%.*}`. A reader that keys on the `FAILED` token alone therefore
  indicts bytes that verified, and collapses "your keyring lacks the key",
  "your recipe forbids the key" and "the download is corrupt" into one word
  the operator cannot act on. Attribution is therefore stage-aware
  (`gsa_fetch::engine::verify_failure`), and the class picks the policy:
  - `verify-failed` — a CHECKSUM failure: the payload is the suspect, so it
    and its signature companions are quarantined and the recipe retried once.
  - `sig-key-unknown`, `sig-key-not-allowed`, `sig-key-untrusted` — TRUST
    failures. Nothing on disk is suspect; the same bytes re-download to the
    same unverifiable signature, so nothing is quarantined, **nothing is
    retried**, and the refusal names the key, the class, this recipe's
    `validpgpkeys` set and the repair (receive the key / fix the recipe's key
    set / pin a key). The two repairs are mutually exclusive, which is exactly
    why one reason word could not carry them.
  - `sig-bad`, `sig-error` — a cryptographic failure with the key present:
    only the signature COMPANIONS are quarantined, and the recipe retries once.
- **v1 prefetches plain-URL sources only** (the `gsa-recipe` classifier,
  never grep): a pure-VCS recipe is `skipped vcs-only`, one with nothing to
  fetch `skipped not-a-candidate`, mixed recipes are prefetched. Such
  packages are never spawned at all.
- **A pinned-bad cached file is quarantined**: renamed
  `<name>.gsa-bad-<ts>` in SRCDEST (plus `.sig`/`.asc`/`.sign` companions)
  and retried ONCE, loudly. makepkg keeps a failing download at its final
  name and re-fails forever; prefetch must never leave the wall standing.
  The recipe's checksums/`validpgpkeys` remain the trust anchor throughout.
  A **signature-trust** failure is the exception (above): the file is not the
  suspect, so only the companions of a cryptographic failure are moved and a
  key problem moves nothing at all.
- **Constants**: 2 attempts (the one quarantine retry aside), 10 s apart;
  prefetch pauses below **5 GiB** free on the cache filesystem (never fails);
  one fetch child in flight, niced/ionice'd, in its own process group, killed
  with the run (one TERM, shared grace, SIGKILL — §K.3). `--prefetch-ahead N`
  bounds the window (default 8); `--no-prefetch` opts out. Both flags are
  build-run flags, mirrored in continuations when set (the default-on run's
  continuation needs none).
- **Operator surface** (owner decision 5): a warning line at failure time,
  a `Prefetch warnings (advisory — lanes retry at build time):` prose
  section, `$STATE_DIR/prefetch.log` (the fetch children's makepkg output),
  and the **additive** `prefetch-warnings: N` scalar on the `format: 2`
  machine block — the count of warning-class fetch outcomes of a *build*
  run (`None`, i.e. absent, when the run had no fetch-ahead participation).
  Never run-record rows: a prefetch failure is not an outcome of any package
  build, so `format: 2` is not bumped (ADR 0003 governs the block).
- **`gsa -Sw` rc interpretation**: advisory means a fetch verdict never
  gates a *build*; a fetch-only run's own rows are its work, so its rc
  follows §G.1 from them (`failed` verdict rows are `failed` rows). A
  `skipped` verdict renders as `succeeded` with its skip reason — `remaining:`
  never re-fetches one — and carries no process code (`rc`/`dur` `-`).
  `--dry-run` renders the fetch plan only (`never-started dry-run`).
- **Continuation mirroring**: `-Sw` is mirrorable (a fetch run's
  continuation reissues the fetch action for its remaining packages);
  `--dry-run`, `--leaf`, `--no-prefetch`, `--prefetch-ahead N` mirror when
  set; the hidden `--fetch-job` seam never mirrors (§D.1).

## Considered options

- Making prefetch opt-in. Rejected: advisory by construction cannot fail a
  run, so default-on is safe and default-off stays unassertable.
- Re-implementing download/checksum/PGP per source. Rejected: rule 15 —
  prefetch and the lane must enforce the identical verification contract,
  which only reusing `makepkg --verifysource` gives.
- Prefetching pure-VCS recipes in v1. Deferred: shared canonical mirrors
  can race a lane's own `download_git`; phase 2 decides `--holdver` policy.
- Warn-only quarantine (never move cache bytes). Rejected: it leaves the
  bad-file wall standing across runs and tools; the rename is loud and
  pin-anchored.
- Prefetch rows in the run record. Rejected (see above): they would poison
  the row stream and force a format bump for data that is not build outcome.

## Consequences

A flaky host now costs a warning instead of a wall in the common case; when
the lane still fails its fetch, the operator already has the failure named
in `prefetch.log` and the prose warning. The window adds at most one niced
network worker outside the lane/job budget (`docs/portability.md`), never
touches pacman/sudo/mutex, and dies with the run. The `prefetch-warnings`
scalar and the verdict vocabulary are additive contract surfaces: new
reason keys need no format bump (§L.2); the fixture
`tests/gsa-fetch-v2.sh` and `crates/gsa-cli/tests/prefetch.rs` pin the
window bound, the advisory gate, the quarantine story and the teardown.
