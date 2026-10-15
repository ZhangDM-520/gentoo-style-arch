#!/usr/bin/env bash
set -euo pipefail

# tests/scheduler-intensity.sh — each --intensity level's lanes/normal-jobs/
# core-jobs plan, the per-lane job budget, and a failing run's drain/resume
# invariants, driven through the NATIVE engine (docs/gsa-contract.md §B.5/§B.8,
# §H.2, §K.1). Expectations are record-derived (docs/MEMORY.md rule 25(j)):
# the budget triple is the intensity-profile plan this fixture pins (the
# docs/portability.md formulas on its fixed GSA_CPU_THREADS/GSA_MEMORY_GIB
# inputs), the resume set comes from the outcome rows, and the continuation
# from the run record — never from prose.
#
# Flip notes (docs/gsa-fixture-migration.md row `tests/scheduler-intensity.sh`):
# the fish argv (--allow-broken-rustc --no-deps --no-sync) retires for the §B
# grammar. The scenario is build-only (the fish runs never passed -i), so it
# runs `gsa -B --leaf --intensity` (§B.5/§B.8) — `-S` would add pacman
# transactions this scenario never pinned; `--no-sync` is a deferred spelling
# (gsa refuses it) and no package here has a version-sync provider. The
# format: 1 rr_scalar/rr_row pins become format: 2 rr2_* pins (§H.2); the
# failure-run exit remaps to §G.1's cone-stop-with-failure 4; the per-lane job
# budget re-pins as §K.1's contract (GSA_BUILD_JOBS exported, MAKEFLAGS/
# NINJAFLAGS rewritten by stripping their -jN and preserving the caller's
# other flags — the fish-era "MAKEFLAGS=-jN injection" is not carried).

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"

fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-intensity-fixture.XXXXXX")
# Root-safe cleanup: the engine writes its state tree as root (W5), so the
# plain rm would leave Permission denied noise even on a passing run.
trap '/usr/bin/sudo -n rm -rf -- "$fixture" 2>/dev/null || rm -rf -- "$fixture" 2>/dev/null || true' EXIT

fail() {
    printf '%s\n' "$1" >&2
    if [ -n "${2:-}" ] && [ -f "$2" ]; then
        sed 's/^/    /' "$2" >&2
    fi
    exit 1
}

# The engine under test: built into the fixture tree (scratch only).
# GSA_TEST_GSA_BIN, when already set to an executable, is that engine (the
# rr-v2.bash run_engine convention) and the scratch build is skipped.
if [ -z "${GSA_TEST_GSA_BIN:-}" ]; then
    cargo build --offline --quiet --target-dir "$fixture/cargo" -p gsa-cli \
        --manifest-path "$gsa_repo_root/Cargo.toml" \
        || fail "cannot build the gsa binary for the fixture"
    GSA_TEST_GSA_BIN="$fixture/cargo/debug/gsa"
fi
[ -x "$GSA_TEST_GSA_BIN" ] || fail "the engine under test is not executable: $GSA_TEST_GSA_BIN"
export GSA_TEST_ENGINE=gsa
export GSA_TEST_GSA_BIN

make_workspace "$fixture" auto auto xhigh

ids=()
for i in $(seq 1 8); do
    id="p$i"
    ids+=("$id")
    add_package "$fixture" "$id"
done

cat >"$fixture/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
if [[ "${GSA_FAKE_FAIL_PACKAGE:-}" == "$(basename "$PWD")" ]]; then
    exit 1
fi
printf 'fake makepkg %s\n' "$PWD"
# The lane must hand its per-lane job budget to the build system (§K.1):
# GSA_BUILD_JOBS is the engine's job-count output, MAKEFLAGS/NINJAFLAGS come
# through rewritten — the caller's -jN stripped, its other flags preserved.
printf 'job flags: MAKEFLAGS=%s NINJAFLAGS=%s GSA_BUILD_JOBS=%s\n' \
    "${MAKEFLAGS:-unset}" "${NINJAFLAGS:-unset}" "${GSA_BUILD_JOBS:-unset}"
sleep "${GSA_FAKE_BUILD_SECONDS:-0.05}"
EOF
chmod +x "$fixture/bin/makepkg"

declare -A expected
# lanes / normal-jobs / core-jobs as the run record reports them (the
# 'parallelism:' sentence is rendering; its wording is pinned once in
# tests/dashboard.sh's prose section).
expected[low]='1 3 3'
expected[medium]='2 3 4'
expected[high]='3 3 6'
expected[xhigh]='4 3 7'
expected[max]='6 3 9'

for level in low medium high xhigh max; do
    # The caller's own job flags are deliberately present: §K.1's rewrite is
    # observable only when there is something to strip and something to keep.
    PATH="$fixture/bin:$PATH" \
        MAKEFLAGS='-j99 -s' NINJAFLAGS='-j98' \
        GSA_CPU_THREADS=24 \
        GSA_MEMORY_GIB=21 \
        run_engine "$fixture" -B --leaf --intensity "$level" \
            --state-dir "$fixture/state-$level" "${ids[@]}"
    output=$FIXTURE_OUTPUT
    [[ $FIXTURE_RC == 0 ]] || fail "$level run failed rc=$FIXTURE_RC:
$output"
    read -r want_lanes want_normal want_core <<<"${expected[$level]}"
    got="$(rr2_scalar lanes <<<"$output") $(rr2_scalar normal-jobs <<<"$output") $(rr2_scalar core-jobs <<<"$output")"
    want="$want_lanes $want_normal $want_core"
    if [[ $got != "$want" ]]; then
        fail "unexpected $level plan (lanes normal-jobs core-jobs): got $got want $want:
$output"
    fi
    if [[ $(rr2_scalar intensity <<<"$output") != "$level" ]]; then
        fail "the $level run recorded intensity $(rr2_scalar intensity <<<"$output"):
$output"
    fi
    plan_jobs=$(rr2_scalar normal-jobs <<<"$output")
    for id in "${ids[@]}"; do
        log="$fixture/state-$level/logs/$id.log"
        grep -F "fake makepkg $fixture/packages/$id" "$log" >/dev/null \
            || fail "$id did not build under $level:" "$log"
        grep -F "GSA_BUILD_JOBS=$plan_jobs" "$log" >/dev/null \
            || fail "lane $id did not export its GSA_BUILD_JOBS=$plan_jobs budget under $level:" "$log"
        grep -F "MAKEFLAGS=-s" "$log" >/dev/null \
            || fail "lane $id did not rewrite MAKEFLAGS (strip -jN, keep -s) under $level:" "$log"
        grep -F "NINJAFLAGS=unset" "$log" >/dev/null \
            || fail "lane $id kept a job flag in NINJAFLAGS under $level:" "$log"
    done
    # Atomic publication (§F.2) leaves no temp names; the run's own result
    # files live under runs/<run-id>/ and are that run's record, not litter.
    if grep < <(find "$fixture/state-$level" -name '*.tmp.*' -print -quit) -q .; then
        fail "a lane publication temp name remained for $level"
    fi
done

# Fixture-owned state tree (W5): the engine creates state-failure/ as root,
# but the output.txt capture below is a fixture-side write INTO that tree —
# create the directory first so it stays fixture-owned and the redirect lands.
mkdir -p "$fixture/state-failure"
PATH="$fixture/bin:$PATH" \
    GSA_CPU_THREADS=24 \
    GSA_MEMORY_GIB=21 \
    GSA_FAKE_FAIL_PACKAGE=p1 \
    GSA_FAKE_BUILD_SECONDS=0.2 \
    run_engine "$fixture" -B --leaf \
        --intensity xhigh --state-dir "$fixture/state-failure" "${ids[@]}"
failing_output=$FIXTURE_OUTPUT
if [[ $FIXTURE_RC == 0 ]]; then
    fail "failure fixture unexpectedly succeeded" "$fixture/state-failure/logs/p1.log"
fi
printf '%s\n' "$failing_output" >"$fixture/state-failure/output.txt"
# §G.1: a cone-stop run with >=1 failed row exits 4 (the failure-run remap of
# the fish-era "non-zero").
[[ $FIXTURE_RC == 4 ]] \
    || fail "cone-stop failure run exited $FIXTURE_RC, want 4 (§G.1):" "$fixture/state-failure/output.txt"
[[ $FIXTURE_RC == "$(rr2_scalar rc <<<"$failing_output")" ]] \
    || fail "the record's rc scalar disagrees with the process exit code:" "$fixture/state-failure/output.txt"
if ! grep < <(rr2_scalar outcome <<<"$failing_output") -qx failed; then
    fail "failure run recorded outcome $(rr2_scalar outcome <<<"$failing_output"):" "$fixture/state-failure/output.txt"
fi
if [[ $(rr2_outcome p1 status <<<"$failing_output") != failed ]]; then
    fail "p1 row wrong in the failure run: $(rr2_outcome p1 <<<"$failing_output")" "$fixture/state-failure/output.txt"
fi
if [[ $(rr2_outcome p1 rc <<<"$failing_output") != 1 ]]; then
    fail "a build failure is lane code 1 (§F.1): $(rr2_outcome p1 <<<"$failing_output")" "$fixture/state-failure/output.txt"
fi
# The resume set is exactly the non-succeeded rows in row order: p1 (failed —
# it must rebuild before its dependents) first, and the lanes that were
# already in flight drain to their own row outcomes, so the set's size is
# deterministic even though which siblings finished is not.
mapfile -t remaining < <(rr2_remaining <<<"$failing_output")
if [[ ${remaining[0]:-} != p1 ]]; then
    fail "the failed package is not first in the resume set: $(rr2_remaining <<<"$failing_output" | tr '\n' ' ')" "$fixture/state-failure/output.txt"
fi
succeeded=$(rr2_outcome_rows <<<"$failing_output" | awk '$2 == "succeeded"' | wc -l)
if [[ ${#remaining[@]} -ne $((${#ids[@]} - succeeded)) ]]; then
    fail "resume set does not cover every non-succeeded row: $(rr2_remaining <<<"$failing_output" | tr '\n' ' ')" "$fixture/state-failure/output.txt"
fi
remaining_rows=$(rr2_remaining <<<"$failing_output" | tr '\n' ' ' | sed 's/ $//')
if [[ $remaining_rows != "$(rr2_continuation remaining <<<"$failing_output")" ]]; then
    fail "continuation remaining disagrees with the rows-derived resume set [$remaining_rows]" "$fixture/state-failure/output.txt"
fi
# The continuation must preserve the plan flavour (continuation rule: the
# resolved --intensity value is mirrored; §H.2).
suggest=$(rr2_continuation command <<<"$failing_output")
if [[ $suggest != *'--intensity xhigh'* ]]; then
    fail "resume command did not preserve intensity:
$suggest" "$fixture/state-failure/output.txt"
fi
if ps -eo args= | grep -F "$fixture" | grep -v grep >/dev/null; then
    fail "lane child remained after failure drain"
fi
if grep < <(find "$fixture/state-failure" -name '*.tmp.*' -print -quit) -q .; then
    fail "a lane publication temp name remained after failure drain"
fi

printf 'scheduler intensity fixture: PASS\n'
