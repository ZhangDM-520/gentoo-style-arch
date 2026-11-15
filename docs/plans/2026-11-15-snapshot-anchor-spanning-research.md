# Research — snapshot anchor spanning (2026-11-15)

Evidence ledger for `2026-11-15-snapshot-anchor-spanning.md`, same directory.
Supersedes the open questions of `2026-11-12-per-recipe-snapshot-boundary.md`.

Frozen provenance: the claims below are as measured on 2026-11-15 and are not
edited as the code moves. Re-run a handle before trusting it; the recheck block
at the bottom is the entry point.

Recheck date: **2026-11-29** (the incident's own claims were dated 11-19; the
pair has already moved once).

## The ask

From the owner: "one possible implementation is to span the snapshot anchor
across monday to friday (1–5): llvm the most critical abi provider sits at
monday, rust-git at wednesday, further downstream abi sensitive consumers at
friday. how to solve the boundary and dependency order and snapshot anchor
edge — walk deeper."

## Method

A compile harness reproduces exactly the failure the incident produced:

```
git -C <llvm-mirror> archive <llvm-sha> llvm/include            | tar x
git -C <rust-mirror> archive <rust-sha> compiler/rustc_llvm/llvm-wrapper | tar x
# synthesize llvm/Config/{llvm-config,abi-breaking,config}.h (generated at cmake time)
g++ -fsyntax-only -std=c++17 -DLLVM_ON_UNIX -I llvm/include \
    compiler/rustc_llvm/llvm-wrapper/PassWrapper.cpp
```

**Harness validity (the reason the verdicts are trusted):** run over the eight
11-02…11-13 instants it reproduces the earlier record's B10 table exactly —
11-02/05/06/07 FINE, **11-08/09/10/11 BROKEN**, 11-12/13 FINE. Any harness that
merely "looked plausible" would not land on that boundary set.

## Claims

Statuses: `verified` = observed by running something; `cited` = read from code
or a commit.

### Q1 — does a weekday span reduce breakage?

| id | claim | status | handle |
| --- | --- | --- | --- |
| S1 | Over 10 anchored Mondays (2026-09-07 … 11-09), **same instant** is **9 FINE / 1 BROKEN**; the broken one is 2026-11-09, the incident. | verified | sweep over `fp()`-selected pairs, `g++ -fsyntax-only`, see Q1 table below |
| S2 | **provider Mon / consumer +2d (Wed)** is **9 FINE / 1 BROKEN** — the same failure set as the status quo (only 11-09). It is **break-even** and does not fix the incident. | verified | same sweep; raw line `span2 llvm@2026-09-14 rust@2026-09-16 COMPILES` |
| S3 | **provider Mon / consumer +4d (Fri)** is **8 FINE / 2 BROKEN** — 09-14 and 09-28, both weeks the same-instant policy gets right (11-09 itself becomes FINE). It **trades** the incident for two new failures. | verified | same sweep |
| S4 | Spanning is therefore **never better than the status quo and can be worse**: +2d is break-even, +4d adds two failures. It is not a remedy in either direction. | verified | S1–S3 |
| S5 | The direction is not a fix in principle: a provider cut earlier than its consumer is an **older** LLVM than the consumer targets. `llvm@11-06 + rust@11-12` → `'getTargetOptions' is not a member`. | verified | `probe.sh 11-06 11-12` |
| S6 | Reverse direction fails too: `llvm@09-18 + rust@09-14` → `'class llvm::TargetOptions' has no member named 'ThreadSafeModule'`; `llvm@11-13 + rust@11-09` → `InitTargetOptionsFromCodeGenFlags` not a member. | verified | `probe.sh` both orders |
| S7 | So neither "earlier" nor "later" is the safety axis: the pair must be **mutually compatible**, a property of the two commits, not of their dates. | verified | S5, S6 + the sweep |

**Q1 table (the centrepiece).** `--first-parent` selection on both mirrors.

| anchor Mon | same | +2d (Wed) | +4d (Fri) |
| --- | --- | --- | --- |
| 2026-09-07 | FINE | FINE | FINE |
| 2026-09-14 | FINE | FINE | **BROKEN** |
| 2026-09-21 | FINE | FINE | FINE |
| 2026-09-28 | FINE | FINE | **BROKEN** |
| 2026-10-05 | FINE | FINE | FINE |
| 2026-10-12 | FINE | FINE | FINE |
| 2026-10-19 | FINE | FINE | FINE |
| 2026-10-26 | FINE | FINE | FINE |
| 2026-11-02 | FINE | FINE | FINE |
| 2026-11-09 | **BROKEN** | **BROKEN** | FINE |

Column totals, recounted from the raw sweep output and not from memory:
**same 9/10** (1 BROKEN), **+2d 9/10** (1 BROKEN, the same week), **+4d 8/10**
(2 BROKEN, two weeks the others pass). An earlier draft of this line and of S2
said "+2d 8/10 — 09-14 and 11-09" while this very table shows 09-14 +2d as
FINE; the raw `sweep.txt` line is `span2 llvm@2026-09-14 rust@2026-09-16
COMPILES`. The table was right and the totals were wrong; corrected 2026-11-15
under review, with the conclusion re-stated as "never better, can be worse"
rather than "strictly increases".

### Q2 — did the incident have the cause the earlier plan assumed?

| id | claim | status | handle |
| --- | --- | --- | --- |
| S8 | The earlier record (B11) reported `llvm-git` on the **11-09** cut and `rust-git` on the **11-02** cut — six days apart. | cited | `2026-11-12-…-research.md` B11 |
| S9 | Re-measured today, **both live pins are the 11-09 boundary**: `llvm #commit=2d12c0df533b` (boundary → `2d12c0df533b`) and `rust #commit=b5fc745fd7cc` (boundary → `b5fc745fd7cc`). | verified | `grep -oE "commit=[0-9a-f]{7,40}" packages/core/{llvm-git,rust-git}/PKGBUILD`; `git rev-list --before=2026-11-09T00:00:00Z -1 main` |
| S10 | The 11-02 reading was **stale pin state from the campaign window**; the recipe repo has since landed `7837c33 … 950600c` carrying the rewrites. | cited | `git -C ~/Projects/gsa-recipe log -- packages/core/{llvm-git,rust-git}/PKGBUILD` |
| S11 | **Therefore the incident was a same-instant failure, not a skew failure** — there was never an asymmetry for a span to correct. | verified | S9 + S1 |
| S12 | The true window is still B5/B9: rename 11-07T18:19Z → fix-merge 11-11T11:06Z. Measured per instant: **BROKEN 11-08/09/10/11**, FINE either side. | verified | the same-instant grid, Q1 harness |

### Q3 — what actually repairs the pair

| id | claim | status | handle |
| --- | --- | --- | --- |
| S13 | `rust-git` carries `0009-compiler-Update-LLVM-24-targetoptions-call.patch` (upstream `ec4acfa`, authored 2026-11-09). | cited | `ls ~/Projects/gsa-recipe/packages/core/rust-git/*.patch`; patch `From ec4acfa0c08e…` |
| S14 | Applied at the **broken** instant (`llvm@11-09` + `rust@11-09`): unpatched **1 error**, patched **0 errors**. | verified | `patch -Np1 < p.patch` from the archive root, then `g++ -fsyntax-only` |
| S15 | So the remedy is **content, not dates**: a patch repairs a cut no weekday rule can make safe, and keeps holding as the pins advance. | verified | S14 |
| S16 | The recipe applies patches with `patch -Np1 < "../$src"` from `$srcdir/rust`, so `-p1` from the archive root is the correct shape. | cited | `packages/core/rust-git/PKGBUILD:97-111` |

### Q4 — the pin selector (the real defect found)

| id | claim | status | handle |
| --- | --- | --- | --- |
| S17 | `snapshot_commit_before` runs `rev-list -1 --before=<boundary> <tip>` with **no `--first-parent`**. | cited | `crates/gsa-recipe/src/sync.rs:2000-2005`; `grep -rn first-parent crates/` → 0 |
| S18 | On the live `rust` mirror, **25 of 30** boundaries pick a commit **off the mainline**. | verified | 30 boundaries at 3-day steps, compare `rev-list --before` vs `--before --first-parent` |
| S19 | **1 of those 30** picks a tree with **no `compiler/`** at all — `4c7bab2be05d` is a **clippy** commit ("fix(map_clone)"), while `--first-parent` picks `5db7f4be8a36`, a rust tree. | verified | `cat-file -p <sha>^{tree}`; `show -s --format=%s` |
| S20 | A pin on such a commit is not a `rust` snapshot: `pkgver()` and the build touch paths the tree does not have. | inferred | S19 (not executed end-to-end) |
| S21 | `llvm` is unaffected — **8/8** boundaries identical with and without `--first-parent` — because it does not merge foreign roots. | verified | the same 8-week comparison against the llvm mirror |
| S22 | `--first-parent` therefore makes the operand "the newest **mainline** commit at or before the boundary", which is what a Monday snapshot of a project means. | verified | S18–S21 |

### Q5 — is a cheap compatibility gate possible?

| id | claim | status | handle |
| --- | --- | --- | --- |
| S23 | A static check (the `codegen::`/`cl::` names the wrapper calls vs declarations in the provider's `llvm/include/llvm/CodeGen`) is **unsound in both directions**. | verified | see the two counterexamples below |
| S24 | False BROKEN: `llvm@11-12 + rust@11-12` reports `InitTargetOptionsFromCodeGenFlags` missing, but that call is `#if LLVM_VERSION_LT(24,0)`-guarded and the pair **compiles**. | verified | name scan + `g++` |
| S25 | False FINE: `llvm@11-02 + rust@11-09` reports nothing missing, but the pair fails on a **different** name (`LLVMParseCommandLineOptionsWith*`). | verified | name scan + `g++` |
| S26 | The only sound probe found is the compile itself; its cost is **1745 ms**, **34 MiB**, **2238 headers** per provider extract, plus a C++ toolchain and the generated `llvm/Config/*.h`. | verified | `git archive … | tar x` timing; `du -sh`; `find -name '*.h' | wc -l` |
| S27 | A single provider header read is cheap (**5 ms**), so a name-level census is affordable — it is *precision* that is missing, not speed. | verified | `git show <sha>:…CommandFlags.h > /dev/null` timing |
| S28 | **Recommended: no engine gate.** The pair risk belongs to the recipe (which owns the patch); a targeted probe fits its `check()`/CI. | inferred | S23–S26 |

### Q6 — the coupling facts a design would have to respect

| id | claim | status | handle |
| --- | --- | --- | --- |
| S29 | `rust` carries `src/llvm-project` as a **gitlink**, and it is a real pin: `160000 commit 0a5579eb649d…` at the 11-12 and 11-13 cuts. | verified | `git -C <rust> ls-tree <sha> src/llvm-project` |
| S30 | That pin is **unusable against our provider**: the submodule URL is the **`rust-lang/llvm-project` fork** (`branch = rustc/23.1-2026-07-22`), and `0a5579eb` is absent from the `llvm/llvm-project` mirror (`cat-file` → could not get object info). | verified | `.gitmodules` at the pin; `git -C <llvm> cat-file -t 0a5579eb` |
| S31 | `llvm-libs-git` declares **no bare-soname provide** (only `aur-llvm-libs-git`, `llvm-libs=<version>`); its `DT_SONAME` is `libLLVM.so.24.0`, so the derived ABI token is over `libLLVM.so.24`, which did **not** move across the rename. | verified | `pacman -Qi llvm-libs-git`; `readelf -d`; `crates/gsa-abi/src/token.rs:1-16` |
| S32 | That is why no wave engaged (C10 in the earlier record): a rename that keeps the soname is invisible to the token, so the ABI gates are structurally blind to this class. | cited | S31 + `docs/gsa-contract.md` 848-851 |
| S33 | The engine **never reads gitlinks**: no crate mentions submodules or mode `160000`. | verified | `grep -rn "160000\|gitlink\|submodule" crates/ --include=*.rs` → 0 |
| S34 | `sync_one` already has the `Graph`, so a cross-recipe rule *could* consult edges — the cost is not plumbing but the fact S7 gives the rule nothing sound to compare. | cited | `crates/gsa-cli/src/prepare.rs:280-331`; `Graph::prerequisites` (`crates/gsa-graph/src/lib.rs:197`) |

## Verdict

1. **The weekday span is refuted.** It is never better than the status quo and
   can be worse (S1–S4), and the axis it assumes is not the safety axis
   (S5–S7).
2. **The incident's premise is refuted.** Both live pins are the same Monday;
   the 11-02 reading was stale (S8–S11).
3. **The pair is already repaired by a patch** (S13–S15), which is the correct
   class of remedy.
4. **One real, chronic defect surfaced: the pin selector is not first-parent**
   (S17–S22). That is what ships.
5. **A compatibility gate is not worth building** (S23–S28), and the substrate
   for a cross-recipe rule is weak (S29–S34).

## Not established

- **U1** — whether the 25/30 off-mainline picks ever produce an *unbuildable*
  rust tree in practice. Counted one clippy tree in 30; the count is not a rate.
- **U2** — whether `--first-parent` changes any published `.SRCINFO` pin in the
  real recipe tree (measured mirror-side only, not re-run over 213 pinned
  recipes).
- **U3** — whether `llvm-git`'s own `pkgver()` relies on a non-first-parent
  commit (it does not merge foreign roots in 8/8 samples, so no evidence, no
  claim).
- **U4** — the semantic (non-name) break class (earlier record's U1) was not
  re-probed; `-fsyntax-only` still sees declarations only.

## Appendix — the harness (the handles behind S1–S7, S12, S14)

Verbatim from the 2026-11-15 session, embedded so the claim handles
(`probe.sh`, `sweep.sh`) stay re-runnable now that the session scratch is gone.
Both need the two mirrors (`llvm-project`, `rust`) under `SRC=~/.gsa-src`, the
distro `g++`, and `GIT_CONFIG_COUNT=0` for every git call (AGENTS.md rule 2).
`llvm/Config/*.h` is synthesized because those headers are generated at cmake
time, not committed.

### `probe.sh` — one pair, one verdict

```bash
#!/bin/bash
# probe.sh LLVM_REPO RUST_REPO WORKDIR LDAY RDAY
# Prints one verdict line: does rust@RDAY's llvm-wrapper compile against llvm@LDAY?
set -u
L=$1; R=$2; base=$3; LD=$4; RD=$5
CONF=llvm/include/llvm/Config
d="$base/cand_${LD}_${RD}"
command rm -rf "$d"; mkdir -p "$d"; cd "$d" || exit 1
l=$(GIT_CONFIG_COUNT=0 git -C "$L" rev-list --before="2026-${LD}T00:00:00Z" -1 main) || exit 1
r=$(GIT_CONFIG_COUNT=0 git -C "$R" rev-list --before="2026-${RD}T00:00:00Z" -1 main) || exit 1
GIT_CONFIG_COUNT=0 git -C "$L" archive "$l" llvm/include 2>/dev/null | tar x
GIT_CONFIG_COUNT=0 git -C "$R" archive "$r" compiler/rustc_llvm/llvm-wrapper 2>/dev/null | tar x
mkdir -p $CONF
cat > $CONF/llvm-config.h <<'EOF'
#ifndef LLVM_CONFIG_H
#define LLVM_CONFIG_H
#define LLVM_VERSION_MAJOR 24
#define LLVM_VERSION_MINOR 0
#define LLVM_VERSION_PATCH 0
#define LLVM_VERSION_STRING "24.0.0git"
#define LLVM_DEFAULT_TARGET_TRIPLE "x86_64-pc-linux-gnu"
#define LLVM_HOST_TRIPLE "x86_64-pc-linux-gnu"
#define LLVM_ENABLE_THREADS 1
#define LLVM_ENABLE_UNWIND_TABLES 1
#define LLVM_ENABLE_DUMP 1
#define LLVM_ENABLE_ABI_BREAKING_CHECKS 0
#define LLVM_ENABLE_ASSERTIONS 0
#define LLVM_HAS_ATOMICS 1
#endif
EOF
cat > $CONF/abi-breaking.h <<'EOF'
#ifndef LLVM_ABI_BREAKING_CHECKS_H
#define LLVM_ABI_BREAKING_CHECKS_H
#endif
EOF
cat > $CONF/config.h <<'EOF'
#ifndef LLVM_CONFIG_CONFIG_H
#define LLVM_CONFIG_CONFIG_H
#define LLVM_ON_UNIX 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_UNISTD_H 1
#define HAVE_FCNTL_H 1
#endif
EOF
out=$(g++ -fsyntax-only -std=c++17 -DLLVM_ON_UNIX -I llvm/include -I compiler/rustc_llvm/llvm-wrapper compiler/rustc_llvm/llvm-wrapper/PassWrapper.cpp 2>&1 | grep -E "error:" | head -2)
if [ -z "$out" ]; then
  echo "llvm@$LD rust@$RD COMPILES"
else
  echo "llvm@$LD rust@$RD BROKEN $(printf '%s' "$out" | head -1 | sed 's/.*error: //' | cut -c1-55)"
fi
```

### `sweep.sh` — the Q1 grid (10 anchor Mondays × 3 policies)

```bash
#!/bin/bash
# sweep.sh WORKDIR OUT — same-instant vs forward-span compatibility over weeks.
# For each anchor Monday M: llvm@M paired with rust@M, rust@M+2d, rust@M+4d.
# Uses --first-parent for both repos (the correct mainline selector).
set -u
L=~/.gsa-src/llvm-project
R=~/.gsa-src/rust
W=$1
OUT=$2
CONF=llvm/include/llvm/Config

mkconf() {
  mkdir -p $CONF
  printf '%s\n' '#ifndef LLVM_CONFIG_H' '#define LLVM_CONFIG_H' \
    '#define LLVM_VERSION_MAJOR 24' '#define LLVM_VERSION_MINOR 0' \
    '#define LLVM_VERSION_PATCH 0' '#define LLVM_VERSION_STRING "24.0.0git"' \
    '#define LLVM_DEFAULT_TARGET_TRIPLE "x86_64-pc-linux-gnu"' \
    '#define LLVM_HOST_TRIPLE "x86_64-pc-linux-gnu"' \
    '#define LLVM_ENABLE_THREADS 1' '#define LLVM_ENABLE_UNWIND_TABLES 1' \
    '#define LLVM_ENABLE_DUMP 1' '#define LLVM_ENABLE_ABI_BREAKING_CHECKS 0' \
    '#define LLVM_ENABLE_ASSERTIONS 0' '#define LLVM_HAS_ATOMICS 1' '#endif' > $CONF/llvm-config.h
  printf '%s\n' '#ifndef LLVM_ABI_BREAKING_CHECKS_H' '#define LLVM_ABI_BREAKING_CHECKS_H' '#endif' > $CONF/abi-breaking.h
  printf '%s\n' '#ifndef LLVM_CONFIG_CONFIG_H' '#define LLVM_CONFIG_CONFIG_H' \
    '#define LLVM_ON_UNIX 1' '#define HAVE_SYS_TYPES_H 1' '#define HAVE_SYS_STAT_H 1' \
    '#define HAVE_UNISTD_H 1' '#endif' > $CONF/config.h
}

fp() { GIT_CONFIG_COUNT=0 git -C "$1" rev-list --first-parent --before="$2" -1 main; }

probe() { # tag llvm-date rust-date
  local tag=$1 LD=$2 RD=$3
  local l r d n
  l=$(fp "$L" "2026-${LD}T00:00:00Z")
  r=$(fp "$R" "2026-${RD}T00:00:00Z")
  d="$W/s_${tag}_${LD}_${RD}"
  command rm -rf "$d"
  mkdir -p "$d"
  cd "$d" || return
  GIT_CONFIG_COUNT=0 git -C "$L" archive "$l" llvm/include 2>/dev/null | tar x
  GIT_CONFIG_COUNT=0 git -C "$R" archive "$r" compiler/rustc_llvm/llvm-wrapper 2>/dev/null | tar x
  if [ ! -f compiler/rustc_llvm/llvm-wrapper/PassWrapper.cpp ]; then
    echo "$tag llvm@$LD rust@$RD SKIP-no-wrapper" >> "$OUT"
    cd "$W"
    return
  fi
  mkconf
  n=$(g++ -fsyntax-only -std=c++17 -DLLVM_ON_UNIX -I llvm/include \
        -I compiler/rustc_llvm/llvm-wrapper \
        compiler/rustc_llvm/llvm-wrapper/PassWrapper.cpp 2>&1 | grep -cE "error:")
  if [ "$n" -eq 0 ]; then
    echo "$tag llvm@$LD rust@$RD COMPILES" >> "$OUT"
  else
    echo "$tag llvm@$LD rust@$RD BROKEN" >> "$OUT"
  fi
  cd "$W"
  command rm -rf "$d"
}

: > "$OUT"
for i in $(seq 0 9); do
  M=$(date -u -d "2026-11-09 -$((i*7)) days" +%Y-%m-%d)
  S2=$(date -u -d "$M +2 days" +%Y-%m-%d)
  S4=$(date -u -d "$M +4 days" +%Y-%m-%d)
  probe same "$M" "$M"
  probe span2 "$M" "$S2"
  probe span4 "$M" "$S4"
done
echo "SWEEP-DONE" >> "$OUT"
```

`probe.sh` deliberately omits `--first-parent` (it is the earlier, plain
selector); `sweep.sh` carries it, which is why the Q1 grid and the S18–S22
selector comparison are separate measurements.

### S14's patch arm

```sh
# inside a cand_<ld>_<rd> tree already extracted and mkconf'd, at 11-09/11-09:
patch -Np1 < ~/Projects/gsa-recipe/packages/core/rust-git/0009-*.patch
g++ -fsyntax-only -std=c++17 -DLLVM_ON_UNIX -I llvm/include \
    -I compiler/rustc_llvm/llvm-wrapper \
    compiler/rustc_llvm/llvm-wrapper/PassWrapper.cpp 2>&1 | grep -c 'error:'
```

## Recheck

```sh
# 1 selector still lacks --first-parent?
grep -n "first-parent" crates/gsa-recipe/src/sync.rs
grep -n 'rev-list", "-1", &format!("--before' crates/gsa-recipe/src/sync.rs

# 2 the live pins are still the same boundary
cd ~/Projects/gsa-recipe
grep -oE "commit=[0-9a-f]{40}" packages/core/llvm-git/PKGBUILD packages/core/rust-git/PKGBUILD
for r in llvm-project rust; do
  B=2026-11-09T00:00:00Z
  GIT_CONFIG_COUNT=0 git -C ~/.gsa-src/$r rev-list --first-parent --before=$B -1 main
done

# 3 off-mainline picks still occur
R=~/.gsa-src/rust
for i in $(seq 0 9); do d=$(date -u -d "2026-11-13 -$((i*3)) days" +%Y-%m-%d)
  a=$(GIT_CONFIG_COUNT=0 git -C $R rev-list --before=${d}T00:00:00Z -1 main)
  b=$(GIT_CONFIG_COUNT=0 git -C $R rev-list --first-parent --before=${d}T00:00:00Z -1 main)
  [ "$a" != "$b" ] && echo "off-mainline $d ${a:0:12} vs ${b:0:12}"
done

# 4 the pair is still patched
ls ~/Projects/gsa-recipe/packages/core/rust-git/0009-*.patch
```
