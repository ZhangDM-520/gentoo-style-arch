#!/usr/bin/env bash
set -euo pipefail

# "Core runs solo" is a scheduler invariant the docs state three times
# (README, docs/architecture.md, docs/MEMORY.md): a core member builds alone
# with its own, larger job budget, because its full -j is the memory peak the
# guard exists for. Nothing asserted it. `tests/scheduler-intensity.sh` pins
# the *plan numbers* (the run record's plan scalars) but not that the
# dispatcher actually withholds other work while a core member runs, and
# `GSA_CPU_THREADS`/`GSA_MEMORY_GIB` only pin the formula that prints them.
#
# The stub makepkg timestamps its own lifetime, so the assertion is about
# observed concurrency rather than about the shape of the code. The invariant
# has two directions, and they need separate scenarios because each passes
# while the other's guard is removed:
#
#   Phase A — the core member is not *dispatched* into a busy pool:
#     1. BASELINE — at least two non-core packages overlapped. Without this,
#        "the core member never overlapped" could be true merely because
#        nothing in the run ever overlapped, which is how such an assertion
#        rots. The durations are staggered so lanes keep freeing while long
#        packages run; with uniform ones every lane frees in the same poll and
#        the guard is never reached.
#     2. the core member had to wait for other work (held back), and no
#        non-core package's interval overlaps the core member's;
#     3. the core member's lane carried the core job budget, and every
#        non-core package's lane carried the normal one — via the §K.1 export
#        (GSA_BUILD_JOBS) and flag rewrite, through the same stub variables
#        the other fixtures use.
#
#   Phase B — nothing is *started* alongside a running core member: with two
#     lanes and the core member first in the run order, the second lane stays
#     idle although a normal package is ready.
#
# The fish-era fixture these assertions come from was falsified before it was
# trusted — disabling the solo fallback fails phase A, removing the
# running-core guard fails phase B, and handing core the normal budget fails
# phase A's budget assertion — and the v2 flip keeps both scenarios and their
# interval-derived expectations.
#
# The core member is deliberately mid-list in phase A, after three normal
# packages that fill every lane, so the "wait until all lanes are idle" path is
# exercised rather than the trivial case where core happens to be dispatched
# first.
#
# Flip notes (docs/gsa-fixture-migration.md row `tests/scheduler-core-solo.sh`):
# the fish argv (--allow-broken-rustc --no-deps --no-sync) retires for the §B
# grammar. The scenario is build-only (the fish runs passed no install flag),
# so it runs `gsa -B --leaf` (§B.5/§B.8). The row's new-contract target cell
# says `gsa -S --leaf …`; `-S` is a deliberate DEVIATION here because it
# transacts real `pacman -U`, which a fixture must never do — `-B` is §B.5's
# build-only spelling with identical §K.2 scheduling semantics, which is all
# this fixture pins. `--no-sync`/`--allow-broken-rustc` are dropped: no
# version-sync provider and no rustc probe is observable in this scenario. The
# format: 1 rr_scalar pins become format: 2 rr2_scalar pins (§H.2:
# normal-jobs/core-jobs/lanes), and the per-lane job budget re-pins as §K.1's
# contract — GSA_BUILD_JOBS exported, MAKEFLAGS/NINJAFLAGS rewritten by
# stripping their -jN and preserving the caller's other flags — so the
# fish-era "MAKEFLAGS=-jN injection" assertion is retired in favour of the
# export + rewrite wording. v2 orders edgeless packages by topology record
# order (the run record's `order:` scalar), so "the core member is first" in
# phase B is expressed through a workspace whose records put core first —
# the two phases need opposite orders, hence one workspace each.

# Diagnostic: this fixture is silent until PASS, so a bare command dying under
# `set -e` (e.g. a $(...) assignment whose pipeline exits non-zero) vanishes
# without a word in a battery run. The ERR trap names the dying line; it
# reports only, the exit status is still errexit's.
trap 'printf "scheduler-core-solo: silent set -e death: rc=%s at line %s: %s\n" "$?" "$LINENO" "$(sed -n "${LINENO}p" "$0")" >&2' ERR

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"

fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-core-solo.XXXXXX")
trap '/usr/bin/sudo -n rm -rf -- "$fixture" 2>/dev/null || rm -rf -- "$fixture" 2>/dev/null || true' EXIT

fail() {
    printf '%s\n' "$1" >&2
    if [ -n "${2:-}" ] && [ -f "$2" ]; then
        sed 's/^/    /' "$2" >&2
    fi
    exit 1
}

# The engine under test: scratch build only when GSA_TEST_GSA_BIN is not
# already set (the rr-v2.bash run_engine convention).
if [ -z "${GSA_TEST_GSA_BIN:-}" ]; then
    cargo build --offline --quiet --target-dir "$fixture/cargo" -p gsa-cli \
        --manifest-path "$gsa_repo_root/Cargo.toml" \
        || fail "cannot build the gsa binary for the fixture"
    GSA_TEST_GSA_BIN="$fixture/cargo/debug/gsa"
fi
gsa_bin="$GSA_TEST_GSA_BIN"
[ -x "$gsa_bin" ] || fail "cargo did not produce $gsa_bin"
export GSA_TEST_ENGINE=gsa
export GSA_TEST_GSA_BIN="$gsa_bin"

# ─── Phase A workspace: the core member mid-list (records: n1..n4, then c1) ─
make_workspace "$fixture" auto auto xhigh

# n1..n4 are ordinary members; c1 is a core member that is also in git, which
# mirrors the real vocabulary (autofdo-git and libclc-git are packages/git
# recipes that are core members).
normal_ids=(n1 n2 n3 n4)
core_id=c1
selection=(n1 n2 n3 c1 n4)
for id in "${normal_ids[@]}" "$core_id"; do
    add_package "$fixture" "$id" "$gsa_meta_any"
done
# c1 is in git AND core: group membership is the record's comma-joined field.
set_topology_record "$fixture" "$core_id" 'git,core' ''

# Each stub records when it started and stopped, plus the per-lane budget and
# the rewritten job flags it was handed (§K.1), so concurrency can be
# reconstructed afterwards. Pipe-delimited so flag values may contain spaces.
cat >"$fixture/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
id=$(basename "$PWD")
printf 'START|%s|%s|%s|%s|%s\n' \
    "$id" "$(date +%s%N)" "${MAKEFLAGS:-unset}" "${GSA_BUILD_JOBS:-unset}" "${NINJAFLAGS:-unset}" \
    >>"${GSA_FAKE_LANE_INTERVALS:?}"
# Staggered on purpose: the two long packages keep lanes busy while the short
# ones end, which is the only situation in which the core member can be
# dispatched too early. With uniform durations every lane frees in the same
# poll and the core member is dispatched into an already-idle pool, so the
# guard is never exercised and the fixture passes for the wrong reason.
duration=$(awk -v want="$id" '$1 == want { print $2 }' "${GSA_FAKE_DURATIONS:?}")
sleep "${duration:-1}"
printf 'END|%s|%s\n' "$id" "$(date +%s%N)" >>"$GSA_FAKE_LANE_INTERVALS"
: >"$PWD/$id-1.0.0-1-any.pkg.tar.zst"
exit 0
EOF
chmod +x "$fixture/bin/makepkg"

durations="$fixture/durations"
cat >"$durations" <<'EOF'
n1 0.5
n2 2.5
n3 2.5
n4 0.5
c1 0.5
EOF

# Reconstructs concurrency from the stub's own timestamps. RECORDED is how
# many packages the run actually started; HELD_BACK counts non-core packages
# that had already started when the core member did (the precondition for the
# solo assertion to mean anything); the overlap counts are the invariant.
analyse() { # $1 = marker file
    awk -F'|' -v core="$core_id" '
        $1 == "START" { start[$2] = $3; flags[$2] = $4; jobs[$2] = $5; ninja[$2] = $6; seen[$2] = 1 }
        $1 == "END"   { stop[$2] = $3 }
        END {
            for (id in seen) {
                count++
                if (id != core) order[n++] = id
            }
            for (i = 0; i < n; i++) {
                a = order[i]
                for (j = i + 1; j < n; j++) {
                    b = order[j]
                    if (start[a] < stop[b] && start[b] < stop[a]) noncore++
                }
                if (start[a] < stop[core] && start[core] < stop[a]) overlapping++
            }
            held = 0
            for (i = 0; i < n; i++)
                if (start[order[i]] < start[core]) held++
            first = 1
            for (i = 0; i < n; i++)
                if (start[order[i]] < start[core]) first = 0
            printf "RECORDED %d\n", count
            printf "HELD_BACK %d\n", held
            printf "CORE_FIRST %d\n", first
            printf "NONCORE_OVERLAPS %d\n", noncore + 0
            printf "CORE_OVERLAPS %d\n", overlapping + 0
            for (id in seen) printf "FLAGS %s %s %s %s\n", id, flags[id], jobs[id], ninja[id]
        }
    ' "$1"
}

marker="$fixture/marker"
: >"$marker"

# The caller's own job flags are deliberately present: §K.1's rewrite is
# observable only when there is something to strip and something to keep.
PATH="$fixture/bin:$PATH" \
    MAKEFLAGS='-j99 -s' NINJAFLAGS='-j98' \
    GSA_CPU_THREADS=24 \
    GSA_MEMORY_GIB=21 \
    GSA_FAKE_DURATIONS="$durations" \
    GSA_FAKE_LANE_INTERVALS="$marker" \
    _IGNOREPKG_CONF="$fixture/pacman.conf" \
    run_engine "$fixture" -B --leaf \
        --lanes 3 --intensity xhigh --state-dir "$fixture/state" "${selection[@]}"
output=$FIXTURE_OUTPUT
printf '%s\n' "$output" >"$fixture/output-a.txt"
[[ $FIXTURE_RC == 0 ]] \
    || fail "the scheduler run failed rc=$FIXTURE_RC:" "$fixture/output-a.txt"
[[ $FIXTURE_RC == "$(rr2_scalar rc <<<"$output")" ]] \
    || fail "the record's rc scalar disagrees with the process exit code:" "$fixture/output-a.txt"

# The plan numbers are DATA: the run record's normal-jobs / core-jobs scalars,
# not the 'parallelism:' sentence (rendering, pinned once in dashboard.sh's
# prose section).
normal_jobs=$(rr2_scalar normal-jobs <<<"$output")
core_jobs=$(rr2_scalar core-jobs <<<"$output")
if [[ $normal_jobs == "$core_jobs" ]]; then
    fail "the xhigh plan does not separate the two budgets (normal-jobs=$normal_jobs, core-jobs=$core_jobs), so the budget assertion below could not tell them apart" \
        "$fixture/output-a.txt"
fi

report=$(
    analyse "$marker"
)

read_value() { # $1 = key
    printf '%s\n' "$report" | awk -v k="$1" '$1 == k { print $2 }'
}

# The run must have exercised the dispatcher for every selected package: each
# selected id has a succeeded row in the record, and the stub's own log saw
# exactly as many builds as the record has rows (a skip would leave rows the
# marker never saw).
rows=$(rr2_outcome_rows <<<"$output")
nrows=$(printf '%s\n' "$rows" | grep -c .)
for id in "${selection[@]}"; do
    [[ $(rr2_outcome "$id" status <<<"$output") == succeeded ]] \
        || fail "$id is not recorded as succeeded, so the run did not exercise the dispatcher:" "$fixture/output-a.txt"
done

recorded=$(read_value RECORDED)
if [[ $recorded != "$nrows" ]]; then
    fail "the stub ran $recorded of $nrows recorded packages; the run did not exercise the dispatcher:" \
        "$fixture/output-a.txt"
fi

# (1) Baseline: the run must be capable of overlap before "no overlap" means
# anything. Three normal packages with three lanes must overlap each other.
noncore_overlaps=$(read_value NONCORE_OVERLAPS)
if ((noncore_overlaps < 1)); then
    fail "no two non-core packages overlapped, so this run cannot show whether the core member was held solo:" \
        "$marker"
fi

# (2) Precondition: the core member must have waited for other work, or the
# solo assertion is vacuous — a core member dispatched first overlaps nothing
# however broken the guard is.
held_back=$(read_value HELD_BACK)
if ((held_back < 1)); then
    fail "no package had started before the core member, so nothing was held back and the solo assertion below proves nothing:" \
        "$marker"
fi

# (3) The invariant.
core_overlaps=$(read_value CORE_OVERLAPS)
if ((core_overlaps != 0)); then
    fail "$core_overlaps package(s) ran alongside the core member $core_id:" "$marker"
fi

# (4) Core carried the core budget, everything else the normal one — §K.1:
# the budget is the exported GSA_BUILD_JOBS, while MAKEFLAGS/NINJAFLAGS arrive
# rewritten (the caller's -jN stripped, its other flags preserved; an all-job
# value is removed entirely).
while read -r tag id flags jobs ninja; do
    [[ $tag == FLAGS ]] || continue
    if [[ $id == "$core_id" ]]; then
        want=$core_jobs
    else
        want=$normal_jobs
    fi
    if [[ $jobs != "$want" ]]; then
        fail "$id ran with GSA_BUILD_JOBS=$jobs, expected $want (§K.1 lane budget):" "$marker"
    fi
    if [[ $flags != "-s" ]]; then
        fail "$id ran with MAKEFLAGS=$flags, expected -s (§K.1 strips the caller's -j99 and keeps its -s):" "$marker"
    fi
    if [[ $ninja != "unset" ]]; then
        fail "$id ran with NINJAFLAGS=$ninja, expected unset (§K.1 removes the caller's all-job -j98):" "$marker"
    fi
done <<<"$report"

# State layout (§J.1): one log per package under logs/; publication is
# atomic (§F.2), so no temp name may survive anywhere in the state tree.
for id in "${selection[@]}"; do
    [ -f "$fixture/state/logs/$id.log" ] \
        || fail "$id has no per-package log under $fixture/state/logs/" "$fixture/output-a.txt"
done
if grep < <(find "$fixture/state" -name '*.tmp.*' -print -quit) -q .; then
    fail "a lane publication temp name remained in the state tree" "$fixture/output-a.txt"
fi

# ─── Phase B: nothing may be *started* alongside a running core member ──────
# Phase A covers one direction: the core member is not dispatched into a busy
# pool. This phase covers the other, which is the guard that actually holds
# work back — with two lanes and the core member first in the run order, lane
# 1 takes core and lane 2 must stay idle although a normal package is ready.
# The two must be separate scenarios: removing this guard leaves phase A
# passing, because by the time the core member gets a lane in phase A every
# normal package has already been started.
#
# v2 derives the run order from the topology record order, not from selection
# order, so this phase gets its own workspace whose records put the core
# member first — phase A needs the opposite order to make "held back" mean
# anything.
ws_b="$fixture/ws-b"
make_workspace "$ws_b" auto auto xhigh
add_package "$ws_b" "$core_id" "$gsa_meta_any"
set_topology_record "$ws_b" "$core_id" 'git,core' ''
add_package "$ws_b" n1 "$gsa_meta_any"

durations_b="$fixture/durations-b"
marker_b="$fixture/marker-b"
cat >"$durations_b" <<'EOF'
c1 1.5
n1 0.5
EOF
: >"$marker_b"

PATH="$fixture/bin:$PATH" \
    MAKEFLAGS='-j99 -s' NINJAFLAGS='-j98' \
    GSA_CPU_THREADS=24 \
    GSA_MEMORY_GIB=21 \
    GSA_FAKE_DURATIONS="$durations_b" \
    GSA_FAKE_LANE_INTERVALS="$marker_b" \
    _IGNOREPKG_CONF="$ws_b/pacman.conf" \
    run_engine "$ws_b" -B --leaf \
        --lanes 2 --intensity xhigh --state-dir "$fixture/state-b" "$core_id" n1
output_b=$FIXTURE_OUTPUT
printf '%s\n' "$output_b" >"$fixture/output-b.txt"
[[ $FIXTURE_RC == 0 ]] \
    || fail "the two-lane core run failed rc=$FIXTURE_RC:" "$fixture/output-b.txt"
[[ $FIXTURE_RC == "$(rr2_scalar rc <<<"$output_b")" ]] \
    || fail "the record's rc scalar disagrees with the process exit code:" "$fixture/output-b.txt"

report_b=$(analyse "$marker_b")
value_b() { # $1 = key
    printf '%s\n' "$report_b" | awk -v k="$1" '$1 == k { print $2 }'
}
nrows_b=$(rr2_outcome_rows <<<"$output_b" | grep -c .)
if [[ $(value_b RECORDED) != "$nrows_b" ]]; then
    fail "the two-lane run started $(value_b RECORDED) of $nrows_b recorded packages:" "$fixture/output-b.txt"
fi
# The scenario framing is the record's own order: the core member must head
# it, or the guard under test is never reached.
if [[ $(rr2_scalar order <<<"$output_b") != "$core_id "* ]]; then
    fail "the core member is not first in the run order, so the guard under test was never reached:" \
        "$fixture/output-b.txt"
fi
if [[ $(value_b CORE_FIRST) != 1 ]]; then
    fail "the core member was not dispatched first, so the guard under test was never reached:" \
        "$marker_b"
fi
if [[ $(value_b CORE_OVERLAPS) != 0 ]]; then
    fail "a package was started alongside the running core member $core_id:" "$marker_b"
fi

printf 'core-solo fixture: PASS\n'
