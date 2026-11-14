# Plan: campaign close-out, openssl swap, system upgrade, and engine review consolidation

> **CLOSED 2026-11-14.** All seven tasks ran; T6's `/code-review` gate closed at
> `open_n=0, blocking_n=0, std=pass, spec=pass` and the work is PR #1. The
> audit clone this plan cites (`~/Projects/.workspace/PERMANENT/gentoo-style-arch`)
> is **retired**: its diff is byte-identical to
> `PERMANENT/gsa-campaign/audit-round2.patch`, and its report and marker are
> archived in `PERMANENT/gsa-campaign/audit-retired/` (sha256 recorded). The
> paths below are the SITUATION AT PLAN TIME, never live pointers.

Written 2026-11-14. Owner is offline until this plan's report lands; all action
permitted. **This file is the runbook: re-read it at every resumed context.**

## 0 · Situation at plan time

| Fact | Value | How to re-check |
| --- | --- | --- |
| Build campaign | `gsa-campaign-crash-resume.service`, run `1794588942-18751`, 36 pkgs, 1 settled (`obs-studio`) | `systemctl --user is-active gsa-campaign-crash-resume`; `bash ~/Projects/.workspace/PERMANENT/gsa-campaign/scripts/mon_run.sh` |
| Long pole | `blender-git` rebuilding after a legacy-marker identity clean (~4.2 h from zero; 5245/7852 at plan time) | `grep -oE '\[[0-9]+/[0-9]+\]' /var/lib/gsa/logs/blender-git.log \| tail -1` |
| Engine binary | sha `65c1a8c46311181a3cda1838e2b315788aef28cb28634e69bfc7ec3eb3e35e0b` | `sha256sum /usr/bin/gsa` |
| Recipe store | `~/.local/share/gsa/recipes`, 186 modified files, `-Sy` hard-resets it | `git -C ~/.local/share/gsa/recipes status --short \| wc -l` |
| Dev recipe tree | `~/Projects/gsa-recipe`, same 186 changes, **durable** | `git -C ~/Projects/gsa-recipe status --short \| wc -l` |
| Durable patch | `~/Projects/.workspace/PERMANENT/gsa-campaign/2026-11-13-pass9-fixes.patch` (185 files) | `ls -la` |
| External audit | clone `~/Projects/.workspace/PERMANENT/gentoo-style-arch`, branch `review/comprehensive-engine-audit`, base `055e4c5`, 77 modified files, uncommitted, **no PR** | `git -C … log --oneline main..review/comprehensive-engine-audit` (empty = no commits) |
| Audit report | `AUDIT_REVIEW_REPORT.md` + `.AUDIT_MARKER` in that clone | `sed -n 1,40p` |

### Global constraints (copy verbatim — reviewer's attention lens)

1. **The build run owns the store.** `makepkg` rewrites `pkgver` in store
   PKGBUILDs mid-run (`blender-git` moved `r167598` → `r167608`). **No commit
   may be made from the store while a run is active.** Author commits from
   `~/Projects/gsa-recipe`, then let `gsa -Sy` propagate, or commit after the run.
2. **Never select `gsa-pm`** — it rebuilds `/usr/bin/gsa` from the remote and
   silently drops uncommitted engine fixes. `bash …/scripts/redeploy_engine.sh`
   before every launch; confirm sha `65c1a8c4…`.
3. **`--no-sync` always** for campaign runs; never `--skip`/`--skip-built`.
4. **Settled = built AND installed.** `.result` rc=0 is not enough; union with
   console `reason=install-failed` rows.
5. **The fixture battery and a live `-S`/`-Ua` are mutually exclusive** — install
   preflights read the real `db.lck`. `tests/run-all.sh` runs only when idle.
6. **The audit clone is read-only until the audit says otherwise.** Its 77
   modified files are the reviewer's live output; never `git add`/`commit`/`clean`
   there. Recover *from* it, write *to* the canonical repo.
7. **Engine change gate** = the `CONTRIBUTING.md` validation block
   (`tools/fmt.sh`, `cargo clippy --workspace --all-targets`,
   `cargo test --workspace -- --test-threads=1`, `cargo build --release`,
   `bash tests/run-all.sh`). There is no CI.
8. **Never commit or push unprompted** — superseded here by the owner's explicit
   "commit and push all changes" for tasks 3 and 4; the recipe/engine repos are
   the only targets, and `AUDIT_REVIEW_REPORT.md`/`.AUDIT_MARKER` never enter a
   commit.
9. Trailers on every commit: `Assisted-by: LLM (human-reviewed)` +
   `Signed-off-by: ZhangDM-520 <jixianqiang1540@gmail.com>`; Copilot co-author
   where it applies.

### File map

| File | Responsibility |
| --- | --- |
| `~/Projects/.workspace/PERMANENT/gsa-campaign/scripts/*.sh` | Run status, engine redeploy, resume launcher, marker pre-seed |
| `~/Projects/.workspace/PERMANENT/gsa-campaign/resume_pkgs.txt` | Current selection (36 pkgs, 2 skipped excluded) |
| `~/Projects/.workspace/PERMANENT/gentoo-style-arch/AUDIT_REVIEW_REPORT.md` | Round 1 ledger (75 fixed) + Round 2 ledger (24 open) + PR plan |
| `~/Projects/gentoo-style-arch` | Canonical engine repo; where audit fixes land |
| `~/Projects/gsa-recipe` | Canonical recipe repo; where recipe edits land |
| `docs/plans/2026-11-14-campaign-closeout-runbook.md` | This plan |
| `docs/JOURNAL.md` | One dense line per action |

---

## Task 1 · Finish the remaining build

**Deliverable:** run `1794588942-18751` exits rc=0 with `failed=[]`, or its
failures are individually diagnosed and fixed.

**Stopping criterion:** `/tmp/resume_rc.txt` exists, `mon_run.sh` prints
`failed=0[]`, and the install-failure union is empty.

### Steps

1. Poll every ~10-15 min: `systemctl --user is-active gsa-campaign-crash-resume.service; bash …/scripts/mon_run.sh`.
   → Window when `/tmp/resume_rc.txt` appears.
2. On rc≠0, read `/tmp/resume.out` tail + the failing package's
   `/var/lib/gsa/logs/<pkg>.log`. Classify: recipe defect / host leftover /
   transient network / OOM. → One classification line in the journal.
3. Diagnose before patching (`--dry-run`, `build()`, `prepare()` idempotence).
   Fix recipes in `~/Projects/gsa-recipe` first, then copy into the store
   (never edit the store directly — it resets).
4. Rebuild only the failed package:
   `sudo -n env GSA_BUILD_DIR=… GSA_MEMORY_GIB=24 gsa -S --no-sync --intensity max --leaf <pkg>`.
   → `rr2`-style rc=0 and an installed version.
5. Repeat 3-4 until the selection is clean.

### Known risk

If the run dies again, `/tmp` is wiped but the run dir and build trees survive.
Re-create scripts from `PERMANENT/gsa-campaign/scripts`. **Pre-seed legacy
toolchain markers before a resume** (`scripts/preseed_toolchain_markers.sh`) —
102 markers were still in the 41-byte legacy format at plan time, and a legacy
marker reads as an identity change and force-cleans the build tree (this cost
4.2 h on `blender-git`).

---

## Task 2 · Verify every package built AND installed

**Deliverable:** a table of roster packages with `built`/`installed` booleans.

**Stopping criterion:** zero roster packages except the withheld `openssl` and
the owner-skipped `libreoffice-fresh`/`onlyoffice-git` are missing either.

### Steps

1. Union the failures:
   ```sh
   R=/var/lib/gsa/runs/$(cat /var/lib/gsa/runs/current); \
   for f in "$R"/*.result; do case $f in *.fetch.result) continue;; esac; \
     awk '$3!=0{print $2}' "$f"; done | sort -u
   grep -o 'lane-failed pkg=[^ ]* .*reason=install-failed' /tmp/resume.out | sed 's/^lane-failed pkg=//; s/ .*//'
   ```
   → Both empty.
2. **Split-output-aware** install check (a naive `pacman -Q <pkgbase>` gives
   10 false "missing"): for each roster recipe, read `.SRCINFO` `pkgname =`
   lines and require at least one installed with the built version.
   → The only genuinely absent outputs are the two owner-skipped recipes.
3. Compare each recipe's built version against its installed version; a
   package installed at an older version than it just built is **not settled**.
   → Zero stale-version mismatches.

---

## Task 3 · Swap in openssl, then `pacman -Syu`

**Deliverable:** `openssl` 4.1.0 installed with no broken link, then a full
system upgrade.

**Stopping criterion:** `pacman -Q openssl` = 4.1.0; `gsa -Qr` shows no new
unresolved `libssl`/`libcrypto` rows; `pacman -Syu` completes rc=0 with no
partial-transaction leftovers.

**This is the highest-risk task. The hazard is real:** the live stack links
`libcrypto.so.3`/`libssl.so.3` (3.6.5 installed); 4.1.0 is a major bump, which
is why it was withheld. AGENTS.md §5 records a black-screen hard freeze from
exactly this class.

### MEASURED FINDINGS (2026-11-14, read-only — evidence, not a plan)

- A built archive already exists, so no rebuild is needed:
  `…/pkgs/openssl-4.1.0-1-x86_64.pkg.tar.zst` (2026-11-12).
- It ships **`libcrypto.so.4` / `libssl.so.4`** and provides
  **`libcrypto.so=4-64`, `libssl.so=4-64`**.
- Installed 3.6.5-1.1 ships `.so.3` and provides `libcrypto.so=3-64`,
  `libssl.so=3-64`.
- **This is a full soname generation move (`.so.3` → `.so.4`), not a patch bump.**
- Blast radius: **175 installed ELF files `DT_NEEDED` `libcrypto.so.3`;
  62 need `libssl.so.3`.**
- **22 installed packages carry a hard pacman pin on `libcrypto.so=3` /
  `libssl.so=3` — including `pacman` itself, `sudo`, `curl`, `openssh`,
  `cryptsetup`, `cargo-c`, `rust-git`, `postgresql`, `mariadb-libs`,
  `openvpn`, `libldap`, `libsasl`, `socat`, `libcurl-compat`,
  `libngtcp2-git`, `lib32-curl`, `lib32-libngtcp2`, `adios2`, `boost-libs`,
  `ostree`, `pdal`.** Name list: `/tmp/openssl_pinners.txt`.
- `/etc/pacman.conf:114` already carries `IgnorePkg = openssl`.

**Consequence:** installing 4.1.0 as-is would break `pacman` and `sudo` — the
tools you would need to repair it. A solo `gsa -S openssl` is **not** the right
move. Rule 69 governs: one atomic heal batch (openssl **plus** every rebuilt
pinner in a single `pacman -U`, GUI stopped), or keep it withheld and hand the
owner the numbers.

### Steps

1. **Pre-image.** `sudo -n cp -p /etc/pacman.conf /etc/pacman.conf.bak-$(date +%F)`;
   record `pacman -Q openssl` and `pacman -Ql openssl | grep -E 'lib(ssl|crypto)'`.
   → Pre-image paths echoed.
2. **Size the blast radius read-only.** Use the engine's own link truth, not a
   `pacman -Qi` loop (that took >3 min and was killed):
   `sudo -n /usr/bin/gsa -Qr | grep -E 'libssl\.so|libcrypto\.so'`
   → The consumer list; also confirms whether 4.1.0's SONAME differs.
3. **Confirm the new SONAME.** Extract the built archive's `provides` and
   `readelf -d` of its `libssl.so`/`libcrypto.so`:
   `tar -xOf <archive> .PKGINFO | grep provides`.
   → Either the SONAME is unchanged (simple) or it moved (heal batch).
4. **Dry-run the install decision read-only:**
   `sudo -n gsa -U --dry-run <openssl archive>` and
   `gsa --install-decide <archive>`.
   → Decision rows all `install`, or a `refuse` row naming what must move with it.
5. **Decide the batch.** If the SONAME moved, this is the atomic heal batch
   (one `pacman -U` with every rebuilt pinning consumer). If not, it is a plain
   `-S`. Record the choice.
6. **Land it**, with the GUI stopped if the SONAME moves (a live dlopen of a
   swapped `libcrypto` is a freeze). Verify immediately:
   `sudo -n /usr/bin/gsa -Qr | grep -cE 'libssl\.so|libcrypto\.so'` → not more
   than the step-2 count.
7. **`pacman -Syu`** only after step 6 is verified. Back up `/etc/pacman.conf`
   first (IgnorePkg closure drifts). Run `sudo -n pacman -Syu --noconfirm`
   only if no IgnorePkg interaction is pending; otherwise run interactively and
   report what it asked.
   → rc=0, `sudo -n gsa --local-db-check health` shows no *new* finding class,
   and `pacman -Dk` reports no broken dependencies.

### Known risk

`pacman -Syu` can replace house packages with stock ones if IgnorePkg is wrong.
Verify with `pacman-conf IgnorePkg` immediately before and after, and repair
with `gsa -Mi --backfill` if the diff is not empty.

---

## Task 4 · Settle in-flight recipe edits (commit and push)

**Deliverable:** the 186-file recipe change set committed and pushed to the
recipe repository, with every touched recipe's `.SRCINFO` in sync.

**Stopping criterion:** `git -C ~/Projects/gsa-recipe status --short` is empty,
`git log origin/main..main` is empty, and a re-run of the `.SRCINFO` sync check
over every touched recipe reports zero mismatches.

### Steps

1. **Wait for Task 1** (constraint 1: the run owns the store). Confirm no
   `makepkg` is running.
2. **Regenerate `.SRCINFO` from the dev tree**, for every recipe the run
   touched — the store copies are volatile. Use `makepkg --printsrcinfo`
   with `GIT_CONFIG_COUNT=0` into `.SRCINFO`.
   → Zero `pkgver` mismatches between `PKGBUILD` and `.SRCINFO`; the ten known
   offenders (`blender-git`, `ffmpeg-git`, `krita-git`, `libglvnd-git`,
   `libva-git`, `scx-scheds-git`, `sdl2-git`, `umbriel-git`,
   `xorg-xwayland-git`, `xwayland-satellite-git`) are gone.
3. **Review the diff by intent**, not by file: separate the genuine fixes
   (gssproxy patch removal, samba PATH, mesa 3 defects, noctalia pin revert,
   libcamera fortify, obs-studio MbedTLS) from the version-sync churn
   (`pkgver`/`pkgrel` bumps). → Two lists, each item justified.
4. **Group into commits** by one intent each; run the recipe-repo checks the
   repo defines (`.SRCINFO` freshness is the main one).
   → Each commit applies and its recipe parses.
5. **Push** to `origin main`.
   → `git log origin/main..main` empty; `git ls-remote origin main` equals local.

---

## Task 5 · Commit and push the engine changes

**Deliverable:** whatever uncommitted engine work exists in
`~/Projects/gentoo-style-arch` committed and pushed, after the validation block.

**Stopping criterion:** `git -C ~/Projects/gentoo-style-arch status --short`
empty, `git log origin/main..main` empty, and the validation block green.

### Steps

1. Inventory the uncommitted engine work:
   `git -C ~/Projects/gentoo-style-arch status --short`, `git diff --stat`.
   → One line saying what it is. If empty, skip to Task 6 with a note.
2. Run the gate: `tools/fmt.sh` → `cargo clippy --workspace --all-targets` →
   `cargo test --workspace -- --test-threads=1` → `cargo build --release`.
   `tests/run-all.sh` only when Task 1-3 are complete (constraint 5).
   → Each command's result recorded verbatim.
3. Commit with the required trailers; push.
   → Same checks as Task 4 step 5.

---

## Task 6 · Consolidate, verify, and merge the external review

**Deliverable:** the audit's 75 Round-1 fixes plus Round-2 remediation landed in
the canonical repo and pushed, or a documented decision to decline specific
findings; and PRs filed per the report's layering.

**Stopping criterion:** `/code-review`'s exit gate holds on the merged tree
(`open_n=0, blocking_n=0, std=pass, spec=pass`), the validation block is green
including `tests/run-all.sh`, and the audit clone is retired.

### Steps

1. **Freeze the audit output.** In the clone, record
   `git diff > ~/Projects/.workspace/PERMANENT/gsa-campaign/audit-round2.patch`
   plus `git status --short` — a durable copy, since the clone is disposable.
   → Patch exists, byte count recorded.
2. **Confirm the delta.** `git -C <clone> diff --stat` must match the report's
   72-file / 5144-insertion table; re-read `.AUDIT_MARKER`
   (`round_2: 24 findings open`). → Matches.
3. **Verify the fixed point.** The clone's base must be a commit the canonical
   repo contains (`055e4c5`). If canonical HEAD has moved, choose: rebase the
   patch or re-run the audit. → One decision, written down.
4. **Round-2 remediation, one finding per commit,** in this order (spec first,
   then standards):
   - `F-R2-A-01` restore `signals::stop_grace_seconds()`.
   - `F-R2-A-02` restore `SupEvent::Signal(sig)` emission + Teardown wording.
   - `F-R2-A-03` drop `.truncate(true)`; `set_len(0)` only after the UID gate.
   - `F-R2-B-01` decouple `.SRCINFO` name authority from `recipe_trusted`;
     reconcile `decision_rows.rs:1521` with `tests/gsa-qa-v2.sh` §c.
   - `F-R2-B-02` cross-role wave overlap + replace `wave.provider` reads.
   - `F-R2-C-01` syntax-check → read-only probe → `privilege_gate` →
     `resolve_workspace(fetch: true)`; never `fetch: true` on `--dry-run`.
   - `F-R2-C-02` honour `inv.standalone_root` in `maint::run_inner`.
   - `F-R2-B-03` fail closed on `retarget_origin` failure.
   - `F-R2-B-04` filter by suffix, let `read_pkginfo` see unreadable archives.
   - `F-R2-C-03` add `GSA_CONF_DIR` isolation to `preflight_contract.rs`.
   - `F-R2-C-04` pass `&resolved_inv` to `build_run_record`.
   - `F-R2-C-05` return `RC_REFUSED` from `dry_run_outcome`.
   - `F-R2-C-06` reconcile `load_user_sets` with contract §C.2 (**decide and
     document** — degrade with a note, or amend §C.2 and refuse rc 3).
   - LOW/NIT: fix the cheap ones (`F-R2-A-06`, `F-R2-B-06`, `F-R2-C-09`,
     `F-R2-C-10`); explicitly defer the rest with a reason in the PR body.
   → After each: the affected crate's tests pass.
5. **Falsify each behavioural fix red-first** (contract §L.4): break one input in
   a scratch copy and watch the check fail naming what broke. In particular
   `F-R2-A-03` needs a foreign-owned state file that must survive with its
   content intact, and `F-R2-B-01` needs `tests/gsa-qa-v2.sh` §c green.
   → Each new check observed failing before the fix.
6. **Round 3 delta review** over the remediation diff; iterate until it finds
   nothing new. → `std=pass`, `spec=pass`.
7. **Full gate**, when idle: `tools/fmt.sh`, `cargo clippy --workspace
   --all-targets`, `cargo test --workspace -- --test-threads=1`,
   `cargo build --release`, `bash tests/run-all.sh` (installed engine).
   → Every command's result recorded.
8. **Remove the audit artifacts** (`AUDIT_REVIEW_REPORT.md`, `.AUDIT_MARKER`)
   from anything committed; they stay only in the clone and the durable patch.
9. **File the PRs** stacked per the report: model/topo/recipe → fetch/sched/
   build → abi/qa/state/install/maint → cli, each green before the next.
   Bodies follow `.github/pull_request_template.md` and tick only commands run.
   → Every PR has a body with real results and a green base.

### Known risk

The report flags a **genuine contract tension** at `F-R2-C-06` (code refuses rc 2
while §C.2 promises degrade) and a **test-vs-fixture conflict** at
`F-R2-B-01` (unit test asserts no `.SRCINFO` read; fixture requires it). Both
need a written decision, not a silent pick — record the decision in the PR body
and, for `F-R2-C-06`, amend the contract if the code wins.

---

## Task 7 · Reconcile the queued enhancements and write the report

**Deliverable:** `AGENTS.md` §6 reconciled against what the campaign learned, and
a final report for the owner.

**Stopping criterion:** each of the five §6 items is either deleted (done),
re-scoped with new evidence, or left with an explicit "not now" reason; the
report states every acceptance criterion's outcome with evidence.

### Steps

1. Re-read `AGENTS.md` §6 in the canonical repo (five items: per-package
   resource measurement; per-lane job adaptation; `core`-alone heterogeneity;
   install-races-build; snapshot pins).
2. Attach campaign evidence to each: the 4.2 h rebuild the legacy-marker gate
   caused; the measured 16 obj/min; the `core`-alone serialisation actually
   observed (one lane held the machine for hours while 35 packages waited);
   the store corruption by a fixture retarget (new pitfall worth recording);
   the identity-marker format change (also a new pitfall).
3. Delete finished items, re-scope the rest, add the new pitfalls to §5.
4. Write the report: per-task outcome, evidence, deviations, what is **not**
   claimed, and what the owner must decide. → Report file path echoed.

---

## Self-review against the request

| Owner requirement | Task |
| --- | --- |
| finish the remaining build | 1 (+2 for the built-AND-installed criterion) |
| check the withheld openssl item; swap it in with no breakage | 3 steps 1-6 |
| finally trigger a `pacman -Syu` | 3 step 7 |
| settle in-flight edits, commit and push | 4 (recipes) + 5 (engine) |
| check the engine PR; verify and merge external review PRs | 6 |
| reconcile queued enhancements, produce a report | 7 |

**Failure modes attached to owners:** (a) store commit during a run → Task 4
constraint 1; (b) identity clean wiping a tree on resume → Task 1 known risk;
(c) `pacman -Syu` replacing house packages → Task 3 step 7; (d) a live dlopen
of a swapped `libcrypto` → Task 3 step 6; (e) audit clone edited by me →
constraint 6; (f) a "green" run that skipped the battery → constraint 5.

**Not in this plan:** any new engine feature; the two research notes' proposals
consumer-expansion filter and per-package measurement) are inputs to Task 7, not
work.
