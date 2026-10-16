#!/usr/bin/env bash
set -uo pipefail

# Run the whole fixture battery. Every fixture is self-contained and
# non-mutating: they build scratch trees under $TMPDIR, diff committed metadata,
# stub sudo/pacman/date through PATH, and assert on the builder's own output, so
# this is safe on a working checkout — and, crucially, safe to run fixtures
# CONCURRENTLY: no fixture writes anything another fixture reads. That rule is
# what the parallel default below rests on; a new fixture that breaks it is a
# bug in the fixture, not a reason to drop -j.
#
# Usage:
#   tests/run-all.sh               # every fixture, in parallel
#   tests/run-all.sh recipe        # only fixtures whose name matches "recipe"
#   tests/run-all.sh -j 4          # cap concurrency at 4
#   tests/run-all.sh --serial      # one at a time (debugging a flaky fixture)
#   RUN_ALL_JOBS=2 tests/run-all.sh
#
# Order is alphabetical (stable and maintenance-free) and the report is printed
# in that order too, regardless of completion order; discovery is recursive with
# tests/assets/ excluded (frozen reference material there never runs standalone),
# so a new fixture needs no edit here. Shared helper code lives in tests/lib/
# under the same two conventions its own header documents: its extension is
# .bash (not .sh) so discovery can never match it, and lib/ is additionally
# excluded here as defence in depth so a future tests/lib/anything.sh cannot
# become a phantom fixture either.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root" || exit 1

jobs=${RUN_ALL_JOBS:-$(nproc 2>/dev/null || echo 4)}
filter=
while (($#)); do
    case $1 in
        -j)
            shift
            jobs=${1:?run-all.sh: -j needs a number}
            ;;
        -j*)
            jobs=${1#-j}
            ;;
        --serial)
            jobs=1
            ;;
        -*)
            printf 'run-all.sh: unknown option: %s\n' "$1" >&2
            exit 2
            ;;
        *)
            filter=$1
            ;;
    esac
    shift
done
[[ $jobs =~ ^[1-9][0-9]*$ ]] || {
    printf 'run-all.sh: jobs must be a positive integer, got: %s\n' "$jobs" >&2
    exit 2
}

mapfile -t fixtures < <(cd "$root/tests" &&
    find . -name '*.sh' ! -name 'run-all.sh' ! -path './assets/*' \
        ! -path './lib/*' -printf '%P\n' | sort)
if ((${#fixtures[@]})) && [[ -n $filter ]]; then
    mapfile -t fixtures < <(printf '%s\n' "${fixtures[@]}" |
        grep -F -e "$filter" || true)
fi

# A filter that matches nothing is a typo, not an empty battery: exiting 0
# with `PASS (0 fixture(s))` would let a mistyped filter silently pass.
if [[ -n $filter && ${#fixtures[@]} -eq 0 ]]; then
    printf 'run-all.sh: fixture filter "%s" matched no fixtures — typo?\n' "$filter" >&2
    exit 2
fi

if ((${#fixtures[@]} == 0)); then
    printf 'fixture battery: PASS (0 fixture(s))\n'
    exit 0
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/gsa-battery.XXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT

# One engine, built once. Fixtures honour the rr-v2.bash GSA_TEST_GSA_BIN
# convention (an already-set executable is used as-is); when it is unset every
# engine fixture builds its own ~5 GiB debug tree under $TMPDIR, and a battery
# run exhausting the 16 GiB /tmp tmpfs (99 MiB free observed, 2026-10-15)
# fails at random: bash here-string temp files and child spawns die with
# ENOSPC/EAGAIN and fixtures fail in unrelated-looking ways. The prebuild
# lands in the repository's target/ (disk, git-ignored), never in $TMPDIR
# scratch; a standalone fixture still builds its own engine as before.
if [[ -z ${GSA_TEST_GSA_BIN:-} || ! -x ${GSA_TEST_GSA_BIN} ]]; then
    cargo build --offline --quiet -p gsa-cli --manifest-path "$root/Cargo.toml" || {
        printf 'run-all.sh: cannot build the gsa binary the fixtures test\n' >&2
        exit 1
    }
    GSA_TEST_GSA_BIN="$root/target/debug/gsa"
fi
[[ -x $GSA_TEST_GSA_BIN ]] || {
    printf 'run-all.sh: engine under test is not executable: %s\n' "$GSA_TEST_GSA_BIN" >&2
    exit 1
}
export GSA_TEST_GSA_BIN

# W4 build-cache isolation: engine runs create their build cache at the
# resolved root (default: the build user's ~/.cache/gsa). The battery keeps
# that hermetic — one scratch cache per battery run, inside $TMPDIR.
export GSA_BUILD_DIR="${GSA_BUILD_DIR:-${TMPDIR:-/tmp}/gsa-battery-build}"

# One fixture in a child shell: stdout+stderr to its own file, rc to its own
# file, so the parent can report everything alphabetically at the end.
run_one() {
    local fixture=$1
    if bash "$root/tests/$fixture" >"$work/$fixture.out" 2>&1; then
        printf '0\n' >"$work/$fixture.rc"
    else
        printf '%s\n' "$?" >"$work/$fixture.rc"
    fi
}
export -f run_one
export root work

printf '%s\n' "${fixtures[@]}" |
    xargs -P "$jobs" -n1 bash -c 'run_one "$1"' _ || exit 1

pass=0
failed=()
for fixture in "${fixtures[@]}"; do
    rc=$(cat "$work/$fixture.rc" 2>/dev/null || printf '127')
    if [[ $rc == 0 ]]; then
        pass=$((pass + 1))
        printf '  ✓ %s\n' "$fixture"
    else
        failed+=("$fixture")
        printf '  ✗ %s\n' "$fixture"
        sed 's/^/      /' "$work/$fixture.out"
        [[ -s $work/$fixture.out ]] ||
            printf '      (fixture produced no output; rc %s)\n' "$rc"
    fi
done

echo ""
if ((${#failed[@]} == 0)); then
    printf 'fixture battery: PASS (%d fixture(s))\n' "$pass"
    exit 0
fi
printf 'fixture battery: FAIL (%d passed, %d failed: %s)\n' \
    "$pass" "${#failed[@]}" "${failed[*]}" >&2
exit 1
