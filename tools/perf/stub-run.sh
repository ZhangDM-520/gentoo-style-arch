#!/usr/bin/env bash
# tools/perf/stub-run.sh — time a full build run against a synthetic roster.
#
#   tools/perf/stub-run.sh [--packages N] [--lanes L] [--jobs J] [--engine BIN]
#
# Nothing is compiled: the workspace comes from the battery's own synthesis
# helpers (tests/lib/fixture-lib.bash) and `makepkg`/`pacman` are stubs, so the
# measurement is the ENGINE's scheduler cost — dispatch, queueing, lane
# bookkeeping, record assembly — not a compiler's. That is the only wall-clock
# number the review can take without an hour-long real build.
#
# The roster is flat (every package in one group, no edges): the point is the
# per-package cost at scale, so add edges only if the question is the
# dispatcher's ordering rather than its throughput.
#
# This is a dev tool, not a fixture: it never runs under tests/run-all.sh.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
packages=32
lanes=auto
jobs=auto
engine=${GSA_TEST_GSA_BIN:-}

while [ $# -gt 0 ]; do
    case $1 in
    --packages) packages=${2:?--packages needs a count}; shift 2 ;;
    --lanes) lanes=${2:?--lanes needs a value}; shift 2 ;;
    --jobs) jobs=${2:?--jobs needs a value}; shift 2 ;;
    --engine) engine=${2:?--engine needs a path}; shift 2 ;;
    *) printf 'stub-run: unknown argument %s\n' "$1" >&2; exit 2 ;;
    esac
done

if [ -z "$engine" ]; then
    engine=$(command -v gsa) || {
        printf 'stub-run: no installed gsa; pass --engine or set GSA_TEST_GSA_BIN\n' >&2
        exit 2
    }
fi
[ -x "$engine" ] || { printf 'stub-run: engine is not executable: %s\n' "$engine" >&2; exit 2; }

source "$root/tests/lib/fixture-lib.bash"
source "$root/tests/lib/rr-v2.bash"

export GSA_TEST_ENGINE=gsa
export GSA_TEST_GSA_BIN=$engine

fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-perf-stub.XXXXXX")
trap '/usr/bin/sudo -n rm -rf -- "$fixture" 2>/dev/null || command rm -rf -- "$fixture"' EXIT

ws=$fixture/ws
make_workspace "$ws" "$lanes" "$jobs" xhigh
stub_sudo "$ws"
stub_makepkg "$ws"
stub_pacman "$ws"
export GSA_FAKE_PACMAN_LOG="$ws/pacman.log"
export PATH="$ws/bin:$PATH"

for i in $(seq 1 "$packages"); do
    add_package "$ws" "p$i"
done

start=${EPOCHREALTIME/./}
run_engine "$ws" -B @git
end=${EPOCHREALTIME/./}
ms=$(( (end - start) / 1000 ))

if [ "$FIXTURE_RC" -ne 0 ]; then
    printf 'stub-run: engine rc=%s\n' "$FIXTURE_RC" >&2
    printf '%s\n' "$FIXTURE_OUTPUT" | tail -15 >&2
    exit 1
fi

built=$(grep -c 'status=succeeded' <<<"$FIXTURE_OUTPUT" || true)
printf 'packages=%s succeeded=%s lanes=%s jobs=%s\n' "$packages" "${built:-0}" "$lanes" "$jobs"
printf 'engine wall: %s ms (%s ms/package)\n' "$ms" "$(( ms / packages ))"
printf 'RESULT packages=%s engine_ms=%s ms_per_package=%s lanes=%s jobs=%s\n' \
    "$packages" "$ms" "$(( ms / packages ))" "$lanes" "$jobs"
