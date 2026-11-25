#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"

scratch=$(mktemp -d "${TMPDIR:-/tmp}/gsa-history.XXXXXX")
trap 'sudo -n rm -rf -- "$scratch" 2>/dev/null || rm -rf -- "$scratch"' EXIT
fail() { printf '%s\n%s\n' "$1" "${FIXTURE_OUTPUT:-}" >&2; exit 1; }

export GSA_TEST_ENGINE=gsa
make_workspace "$scratch" auto auto medium
add_package "$scratch" p1
export GSA_BUILD_HISTORY="$scratch/history.tsv"
export GSA_CPU_THREADS=12 GSA_MEMORY_GIB=12
export PATH="$scratch/bin:$PATH"

cat >"$scratch/bin/makepkg" <<'STUB'
#!/usr/bin/env bash
set -eu
printf "fixture makepkg started\n"
sleep "${GSA_FAKE_BUILD_SECONDS:-0}"
python3 -c 'memory = bytearray(64 * 1024 * 1024); memory[::4096] = bytes([1]) * (len(memory) // 4096)'
case ${GSA_FAKE_FAIL_PACKAGE:-} in p1) exit 1 ;; esac
: >p1-1.0.0-1-any.pkg.tar.zst
STUB
chmod +x "$scratch/bin/makepkg"

run_engine_user "$scratch" -M --export-build-history
[[ $FIXTURE_RC == 0 && $FIXTURE_OUTPUT == "gsa-build-history-v1" && ! -e $GSA_BUILD_HISTORY ]] ||
    fail "export of absent history must be empty and read-only"
run_engine_user "$scratch" --complete -M --export-build
[[ $FIXTURE_RC == 0 && $FIXTURE_OUTPUT == --export-build-history* ]] || fail "export command completion"
run_engine_user "$scratch" -B --dry-run --leaf --state-dir "$scratch/dry" p1
[[ $FIXTURE_RC == 0 && ! -e $GSA_BUILD_HISTORY ]] || fail "dry run wrote history"

# Two independent helper processes must merge without losing either key.
for pkg in concurrent-a concurrent-b; do
    (
        printf 'gsa-build-history-v1\n%s\t%s\tgcc\t1\t4096\t1\t1\n' "$pkg" "$(uname -m)" |
            GSA_BUILD_HISTORY="$scratch/concurrent.tsv"                 "${GSA_TEST_GSA_BIN:-gsa}" --build-history-user merge
    ) &
    if [[ $pkg == concurrent-a ]]; then first_merger=$!; else second_merger=$!; fi
done
wait "$first_merger"
wait "$second_merger"
[[ $(grep -c '^concurrent-' "$scratch/concurrent.tsv") == 2 ]] || fail "concurrent merge lost a sample"

# A custom history path cannot alias a lock inode.
candidate=${GSA_TEST_GSA_BIN:-gsa}
sample=$(printf 'gsa-build-history-v1\np1\t%s\tgcc\t1\t4096\t1\t1\n' "$(uname -m)")
GSA_BUILD_HISTORY="$scratch/build-history.lock" "$candidate" \
    --build-history-user merge <<<"$sample" || fail "custom filename collided with the old lock"
[[ $(cat "$scratch/build-history.lock") == "$sample" ]] || fail "custom history was not saved"
if alias_output=$(GSA_BUILD_HISTORY="$scratch/reserved.gsa-lock" "$candidate" \
    --build-history-user merge <<<"$sample" 2>&1); then
    fail "history merge accepted a reserved lock filename"
fi
[[ $alias_output == *'.gsa-lock are reserved'* ]] || fail "lock alias refusal omitted the reason"
GSA_BUILD_HISTORY="$scratch/reserved.gsa-lock" run_engine_user "$scratch" -M --export-build-history
[[ $FIXTURE_RC == 3 && $FIXTURE_OUTPUT == *'.gsa-lock are reserved'* ]] ||
    fail "export accepted a reserved lock filename"
(
    exec 9>"$scratch/busy.tsv.gsa-lock"
    flock -x 9
    if busy_output=$(timeout 3 env GSA_BUILD_HISTORY="$scratch/busy.tsv" "$candidate" \
        --build-history-user merge <<<"$sample" 2>&1); then
        fail "history merge bypassed a busy lock"
    fi
    [[ $busy_output == *'cannot lock build history'* && ! -e $scratch/busy.tsv ]] ||
        fail "history did not report bounded contention"
)

GSA_BUILD_HISTORY=off run_engine "$scratch" -B --leaf --state-dir "$scratch/off" p1
[[ $FIXTURE_RC == 0 && $FIXTURE_OUTPUT == *'pkg=p1 core=0 jobs=2'* && ! -e $GSA_BUILD_HISTORY ]] ||
    fail "baseline fallback with history disabled"

run_engine "$scratch" -B --leaf --state-dir "$scratch/one" p1
[[ $FIXTURE_RC == 0 && $FIXTURE_OUTPUT == *'pkg=p1 core=0 jobs=2'* ]] || fail "initial baseline assignment"
if [[ ! -f $GSA_BUILD_HISTORY ]]; then
    [[ $FIXTURE_OUTPUT == *'lane_accounting_unavailable'* ]] || fail "successful build did not sample its scope"
    printf 'scheduler history fixture: accounting unavailable, fallback PASS\n'
    exit 0
fi

[[ -O $GSA_BUILD_HISTORY ]] || fail "history is not owned by the build user"
awk -F '\t' 'NR==2 { valid=$1=="p1" && $4==2 && $5>=67108864 && $6>0 && $7>0 }
    END { exit !(NR==2 && valid) }' "$GSA_BUILD_HISTORY" ||
    fail "history must account for the memory-using descendant"
run_engine_user "$scratch" -M --export-build-history
[[ $FIXTURE_RC == 0 && $FIXTURE_OUTPUT == "$(cat "$GSA_BUILD_HISTORY")" ]] || fail "export differs from user history"

run_engine "$scratch" -B --leaf --state-dir "$scratch/two" p1
[[ $FIXTURE_RC == 0 && $FIXTURE_OUTPUT == *'pkg=p1 core=0 jobs=4'* ]] || fail "learned worker assignment"
before=$(cat "$GSA_BUILD_HISTORY")
GSA_FAKE_FAIL_PACKAGE=p1 run_engine "$scratch" -B --leaf --state-dir "$scratch/fail" p1
[[ $FIXTURE_RC == 4 && $(cat "$GSA_BUILD_HISTORY") == "$before" ]] || fail "a failed build polluted history"
(
    GSA_FAKE_BUILD_SECONDS=10 run_engine "$scratch" -B --leaf --state-dir "$scratch/interrupted" p1
    printf '%s\n' "$FIXTURE_RC" >"$scratch/interrupt-rc"
    printf '%s\n' "$FIXTURE_OUTPUT" >"$scratch/interrupt-output"
) &
interrupted_run=$!
for ((attempt=0; attempt<200; attempt++)); do
    started=$(find "$scratch/interrupted/runs" -name 'p1.started' -print -quit 2>/dev/null || :)
    if [[ -n $started ]] && grep -q "fixture makepkg started" "$scratch/interrupted/logs/p1.log"; then
        break
    fi
    sleep .05
done
[[ -n $started ]] && grep -q "fixture makepkg started" "$scratch/interrupted/logs/p1.log" ||
    fail "interrupted build never started"
supervisor=$(sed -n 's/^pid=\([0-9]*\) .*/\1/p' "${started%/*}/run.open")
[[ $supervisor =~ ^[1-9][0-9]*$ ]] || fail "missing supervisor PID"
sudo -n kill -INT "$supervisor"
wait "$interrupted_run"
[[ $(cat "$scratch/interrupt-rc") == 130 && $(cat "$GSA_BUILD_HISTORY") == "$before" ]] ||
    fail "an interrupted build polluted history or lost its signal outcome"
printf 'scheduler history fixture: accounting and adaptive assignment PASS\n'
