# Research: should consumer expansion skip languages that are not installed?

Research date 2026-11-13. Engine HEAD `055e4c5`. Recipe store 2026-11-13.
Status: **research only — no code changed.**

## Answer

**Yes, and the case is stronger than it looks, but the naive form is unsafe.**

A package that is installed nowhere owns no ELF files in the installed view, so
it cannot be the thing consumer expansion exists to protect: `linked_consumers`
iterates `InstalledView.packages()` and can never name it (C15). Expansion's
guarantee — rebuild every consumer so none links a moved soname — is therefore
*vacuous* for an absent consumer. Measured on today's host, the whole roster
contains exactly two such recipes (`libreoffice-fresh`, `onlyoffice-git`), both
**terminal leaves with zero consumers of their own** (C9, C10), so filtering
them is safe today and reproduces the owner's reported symptom in the plan
(C7).

But the safety comes from the data, not the structure: filtering a
not-installed package that *does* have a selected consumer would drop a
genuinely needed rebuild (C11). A shipped filter must therefore be
**consumer-aware** (drop only a node with no remaining consumer in the plan),
not a flat "not installed ⇒ drop".

## Claims

| id | claim | status | source | handle | version | recheck | falsification |
| --- | --- | --- | --- | --- | --- | --- | --- |
| C1 | `consumer_closure` is pure reverse reachability, no install input | cited | code | `crates/gsa-graph/src/lib.rs:204-221` (blob `ace7723b`) | HEAD `055e4c5` | 2027-02-13 | signature read in full |
| C2 | `select.rs` has no installed-DB access; `Ctx` = project/graph/db/user_sets | cited | code | `crates/gsa-cli/src/select.rs:24-29` (blob `aa526bad`) | HEAD `055e4c5` | 2027-02-13 | every `installed` hit checked, not the first |
| C3 | closure comes from `closure_of()` → `consumer_closure`, unfiltered | cited | code | `crates/gsa-cli/src/select.rs:690-699` | HEAD `055e4c5` | 2027-02-13 | read both branches |
| C4 | a symmetric precedent already exists for prerequisites | cited | code | `crates/gsa-cli/src/prepare.rs:515-537`, `:964-1003`; contract §C.3 amendment 2026-11-11 | HEAD `055e4c5` | 2027-02-13 | contract text matches code |
| C5 | the ABI wave recomputes its own closure and cannot be silenced by a selection filter | cited | code | `crates/gsa-abi/src/wave.rs:354-372`, `:288-299` | HEAD `055e4c5` | 2027-02-13 | traced all three wave terms |
| C6 | `--leaf` on an `abi=must` provider yields exactly that package | cited | experiment | `gsa -S --dry-run --leaf qt5-multimedia` → 1 row (same for `qt6-multimedia`) | HEAD `055e4c5` | 2027-02-13 | single-shot; no token move present |
| C7 | 35 named packages plan as 37; the 2 extras are the skipped app consumers | cited | experiment | `gsa -S --dry-run …` → 37 rows, `comm -13` ⇒ `libreoffice-fresh onlyoffice-git` | HEAD `055e4c5` | 2027-02-13 | reproduces the owner symptom |
| C8 | both skipped packages are app consumers of selected providers | cited | code | `config/topology.conf` records; `comm -12` vs selection | store 2026-11-13 | 2027-02-13 | — |
| C9 | across all 667 records no seed drags a not-installed package that has consumers | cited | experiment | python reverse-closure sweep ⇒ 0 dangerous seeds | store 2026-11-13 | 2027-02-13 | exhaustive over the roster |
| C10 | both not-installed packages are terminal leaves | cited | experiment | reverse graph ⇒ `libreoffice-fresh: []`, `onlyoffice-git: []` | store 2026-11-13 | 2027-02-13 | — |
| C11 | a flat filter is unsafe in general; the predicate must be consumer-aware | **inferred** | code | derived from C9/C10 (safety is data-driven) | HEAD `055e4c5` | 2027-02-13 | not falsifiable today: no such node exists |
| C12 | the prerequisite seam is called by exactly three verbs (run, plan, `-Sw`); `-Sl` keeps the selection | cited | code | `build.rs:171`, `build.rs:993`, `fetch.rs:66`; contract §C.3 | HEAD `055e4c5` | 2027-02-13 | counter checked per caller |
| C13 | order is prerequisites → wave; a filter at the prerequisite seam runs *before* the wave | cited | code | `build.rs:171-221` | HEAD `055e4c5` | 2027-02-13 | call order read |
| C14 | a wave re-add legitimately wins over an earlier drop; placing the filter after the wave is fail-closed | **inferred** | code | `build.rs:221` `extend_selection`; `wave.rs:288-372` | HEAD `055e4c5` | 2027-02-13 | not empirically falsified |
| C15 | an absent package cannot be an endangered consumer (link truth is installed-only) | cited | code | `crates/gsa-abi/src/rows.rs:183-200`; `view.rs:93` | HEAD `055e4c5` | 2027-02-13 | iteration source read directly |
| C16 | `Selection.finish` keeps seeds separate from closure, so named vs added is distinguishable | cited | code | `crates/gsa-cli/src/select.rs:605-631` | HEAD `055e4c5` | 2027-02-13 | — |
| C17 | a fixture template exists (fabricated installed DB via `pacman-conf DBPath`) | cited | code | `tests/project.sh:1053-1200` §10 | HEAD `055e4c5` | 2027-02-13 | — |

Rows C11 and C14 are `inferred` and **do not support** the answer; they are the
design constraints a plan must honour.

## Contradictions

None found. Sources agree that expansion is install-blind and that the ABI wave
is independent.

## Unknowns

1. **Whether a consumer-aware filter is worth building at all.** Today it saves
   two leaf packages. A cheap falsifiable probe: count how often a roster
   package is not-installed *and* has consumers over the coming weeks. If that
   stays at zero, the honest fix is `--leaf`, not a new mechanism.
2. **Whether `--leaf` is the right escape hatch.** `--leaf` already produces
   exactly the 35-package plan (verified: 35 rows, zero extras). A user who
   wants "rebuild these and their consumers, but skip anything absent" has no
   spelling today, but they also have no need for one if the two are the same
   set.
3. **ABI wave interaction under a real token move.** C6 ran without a movement,
   so it does not prove the wave stays quiet when a provider's soname actually
   moves. That needs a real rebuild, not a dry run.
4. **Split-package semantics.** `onlyoffice-git` is not installed at all, but a
   split recipe with *one* installed output is deliberately treated as
   installed by the prerequisite rule (C4/contract). The same rule should
   govern a consumer filter, and that is a decision, not a derivation.

## Recheck

Re-run the gate when the version moves, in this order:

```sh
# 1. is expansion still install-blind?
grep -n 'installed' crates/gsa-cli/src/select.rs

# 2. the symptom, from a neutral cwd
sudo -n env GSA_BUILD_DIR=… GSA_MEMORY_GIB=24 gsa -S --dry-run --no-sync \
  --intensity max --lanes 6 --jobs 3 <selection> | grep -c never-started

# 3. the exhaustiveness sweep (C9/C10) — swap the store path if it moved
python3 - <<'PY'
import subprocess, os
store=os.path.expanduser('~/.local/share/gsa/recipes')
recs={}
for ln in open(os.path.join(store,'config/topology.conf')):
    ln=ln.rstrip('\n')
    if not ln or ln.lstrip().startswith('#') or '|' not in ln: continue
    f=ln.split('|')
    if len(f)<4: continue
    recs[f[0]]={'deps':[d for d in f[3].split(',') if d]}
rev={r:set() for r in recs}
for r,v in recs.items():
    for d in v['deps']:
        if d in rev: rev[d].add(r)
inst={l.split(' ')[0] for l in
      subprocess.run(['pacman','-Q'],capture_output=True,text=True).stdout.split('\n') if l}
def names(rid):
    p=os.path.join(store,recs[rid].get('dir',''),'.SRCINFO')
    out={rid}
    try:
        for l in open(p):
            if l.startswith(('pkgname = ','pkgbase = ')): out.add(l.split(' = ',1)[1].strip())
    except FileNotFoundError: pass
    return out
notinst=[r for r in recs if not (names(r)&inst)]
print('not-installed:',notinst)
def closure(s):
    seen=set(s); q=list(s)
    while q:
        n=q.pop()
        for c in rev[n]:
            if c not in seen: seen.add(c); q.append(c)
    return seen
danger=[(s,h) for s in recs for h in (closure([s])&set(notinst)) if rev[h]]
print('dangerous seeds:',danger)
PY
```

Gate result on 2026-11-13: orphan 0, unsupported answered-questions 0, open 0,
unexported 0.
