#!/usr/bin/env bash
set -euo pipefail

# build-tools dispatch band + closed-roster fixture.
#
# Why a NEW file rather than a section in scheduler-core-solo.sh: that
# fixture's subject is narrowly the "core runs solo" invariant (two
# falsification phases around concurrency intervals and lane budgets); the
# subject pinned here is the dispatch ORDER band and roster validation, with
# its own spawn-order stub and loader cases — folding it in would muddy both
# the file's documented subject and its analyse() machinery.
#
# The sixth group `build-tools` is a SCHEDULING CLASS with exactly one
# behavioural effect: whenever the lane dispatcher (run_lanes' pick_next
# ready site) picks the next ready package, build-tools members are picked
# BEFORE all other ready packages. Build-order edges are stronger ALWAYS —
# the band only reorders packages that are ALREADY ready (topo order /
# prerequisite waits / deferred waits win), and every other surface keeps
# topological build order: plan, run-record rows/order (a range indexes that
# order), --list, --dry-run. Membership is dual: every build-tools member
# also carries core (core's solo/auto-install semantics untouched), so the
# synthetic members carry 'core,build-tools' — which also pins that the
# loader accepts the new name in comma groups fields.
#
# Pinned here (fake makepkg/sudo/pacman only; nothing is built or installed):
#   1. roster/loader: --list counts build-tools (a dual member counts in
#      BOTH its groups — the documented double-count), -l -g build-tools
#      selects it, -g build-tools,core dedupes the dual member, and a record
#      naming an unknown group still errors — the roster is CLOSED to six.
#   2. band: a normal package first in topo order and a ready build-tools
#      member after it → the build-tools member is dispatched first.
#   3. edges win: a build-tools member consuming a normal package never
#      STARTS before its slow prerequisite has finished.
#   4. no build-tools member in the set → dispatch order is exactly plan
#      (= topo) order: sets without the group see no behavioural change.
#
# Each scenario is a section wrapped in a ( subshell ) with its own scratch
# workspace under $TMPDIR. GSA_FAKE_SPAWN_LOG captures the dispatch order
# (SPAWN/END timestamps from the fake makepkg) and GSA_FAKE_BUILD_SECONDS
# makes the early-dispatched package slow, so a wrong pick order cannot hide
# behind timing. Exit status, logs and child-process cleanup are asserted on
# every build scenario.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-dispatch-order.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    printf '%s\n' "$1" >&2
    if [ -n "${2:-}" ] && [ -f "$2" ]; then
        sed 's/^/    /' "$2" >&2
    fi
    exit 1
}

# Oracle-shaped dispatch stub: SPAWN/END timestamp lines in
# $GSA_FAKE_SPAWN_LOG (the dispatch-order channel), one sleep from
# $GSA_FAKE_BUILD_SECONDS per build, then the usual trivial archive.
write_dispatch_stub() { # $1 = workspace dir
    cat >"$1/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
id=$(basename "$PWD")
printf 'SPAWN %s %s\n' "$id" "$(date +%s%N)" >>"${GSA_FAKE_SPAWN_LOG:?}"
sleep "${GSA_FAKE_BUILD_SECONDS:-0.05}"
printf 'END %s %s\n' "$id" "$(date +%s%N)" >>"${GSA_FAKE_SPAWN_LOG:?}"
: >"$PWD/$id-1.0.0-1-any.pkg.tar.zst"
exit 0
EOF
    chmod +x "$1/bin/makepkg"
}

listed_rows() { # listing output on stdin -> the selected rows, in build order
    sed -n '/Selected packages in build order/,$p' \
        | grep -E '^ +[0-9]+\. ' | awk '{print $2}' | tr -d '\r'
}

dry_rows() { # dry-run output on stdin -> the shown build-order rows
    sed -n '/Build order (dry run):/,/^Total:/p' \
        | grep -E '^ +[0-9]+\. ' | awk '{print $2}' | tr -d '\r'
}

spawn_ids() { # $1 = spawn log -> SPAWN ids in dispatch order
    awk '$1 == "SPAWN" { print $2 }' "$1"
}

stamp() { # $1 = log, $2 = SPAWN|END, $3 = id -> nanosecond timestamp
    awk -v kind="$2" -v id="$3" '$1 == kind && $2 == id { print $3; exit }' "$1"
}

assert_clean() { # $1 = workspace, $2 = state dir — children drained, no lane result artifacts
    if ps -eo args= | grep -F "$1" | grep -v grep >/dev/null; then
        printf 'a lane child remained after the run of %s:\n' "$1" >&2
        ps -eo pid=,ppid=,args= | grep -F "$1" | grep -v grep >&2 || true
        exit 1
    fi
    if find "$2/logs" -maxdepth 1 -name '.lane*.result*' -print -quit | grep -q .; then
        printf 'a lane result artifact remained after the run of %s\n' "$1" >&2
        exit 1
    fi
}

# ─── 1. Roster: loader accepts build-tools, -g selects it, roster stays closed ─
(
    set -euo pipefail
    ws="$fixture/roster/ws"
    make_workspace "$ws" 1 2 low
    add_package "$ws" n1 "$gsa_meta_any" git
    add_package "$ws" c1 "$gsa_meta_any" core
    add_package "$ws" t1 "$gsa_meta_any" git
    # Dual membership is the vocabulary: every build-tools member also
    # carries core. This record pins the loader accepts the new name in a
    # comma groups field at all.
    set_topology_record "$ws" t1 'core,build-tools' ''

    run_builder fish "$ws/build-all.fish" --list
    ((FIXTURE_RC == 0)) || fail "--list rejects a build-tools topology (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    printf '%s\n' "$FIXTURE_OUTPUT" | grep -E '^ +build-tools: +1 packages$' >/dev/null \
        || fail "--list group footer does not count build-tools (want 1 member): $FIXTURE_OUTPUT"
    # Double-counting a dual member is the documented behaviour (README does
    # the same for stable,core): t1 counts in core AND in build-tools.
    printf '%s\n' "$FIXTURE_OUTPUT" | grep -E '^ +core: +2 packages$' >/dev/null \
        || fail "--list group footer does not double-count the dual member (want core=2): $FIXTURE_OUTPUT"

    run_builder fish "$ws/build-all.fish" -l -g build-tools
    ((FIXTURE_RC == 0)) || fail "-l -g build-tools failed (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    rows=$(printf '%s\n' "$FIXTURE_OUTPUT" | listed_rows | tr '\n' ' ')
    [[ $rows == "t1 " ]] || fail "-l -g build-tools listed [$rows], want [t1]"

    run_builder fish "$ws/build-all.fish" -l -g build-tools,core
    ((FIXTURE_RC == 0)) || fail "-l -g build-tools,core failed (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    rows=$(printf '%s\n' "$FIXTURE_OUTPUT" | listed_rows | sort | tr '\n' ' ')
    [[ $rows == "c1 t1 " ]] \
        || fail "-g build-tools,core must dedupe the dual member t1, got rows [$rows]"

    # Closed roster: an unknown group still errors, and the error lists all
    # six names (the roster is stated once, in the builder).
    bad="$fixture/roster/bad"
    make_workspace "$bad" 1 2 low
    add_package "$bad" bad1 "$gsa_meta_any" git
    set_topology_record "$bad" bad1 'git,bogusgrp' ''
    run_builder fish "$bad/build-all.fish" --list
    ((FIXTURE_RC != 0)) || fail "loader accepted a record naming unknown group bogusgrp: $FIXTURE_OUTPUT"
    printf '%s\n' "$FIXTURE_OUTPUT" | grep -F 'unknown group in topology record bad1: bogusgrp' >/dev/null \
        || fail "unknown-group error does not name the offender: $FIXTURE_OUTPUT"
    printf '%s\n' "$FIXTURE_OUTPUT" | grep -F '(allowed: git,stable,core,misc,app,build-tools)' >/dev/null \
        || fail "unknown-group error does not list the six-name roster: $FIXTURE_OUTPUT"
)

# ─── 2. Band: a ready build-tools member is dispatched first ─────────────────
# n1 precedes t1 in topo order (no edge either way: both ready at start) and
# is deliberately named first — without the band the dispatcher picks n1.
# t1 also carries core, so it runs solo once picked; the band decides WHICH
# ready package is picked, never the solo rule.
(
    set -euo pipefail
    ws="$fixture/band/ws"
    make_workspace "$ws" 2 2 xhigh
    add_package "$ws" n1 "$gsa_meta_any" git
    add_package "$ws" t1 "$gsa_meta_any" git
    set_topology_record "$ws" t1 'core,build-tools' ''
    write_dispatch_stub "$ws"
    stub_sudo "$ws"
    stub_pacman "$ws"

    export PATH="$ws/bin:$PATH"
    export GSA_STATE_DIR="$fixture/band/state"
    export GSA_CPU_THREADS=24 GSA_MEMORY_GIB=21
    export GSA_FAKE_SPAWN_LOG="$fixture/band/spawn.log"
    export GSA_FAKE_PACMAN_LOG="$fixture/band/pacman.log"
    export GSA_FAKE_BUILD_SECONDS=1

    run_builder fish "$ws/build-all.fish" \
        --allow-broken-rustc --no-deps --no-sync --lanes 2 --intensity xhigh n1 t1
    ((FIXTURE_RC == 0)) || fail "the band run failed (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"

    mapfile -t sp < <(spawn_ids "$GSA_FAKE_SPAWN_LOG")
    [[ ${#sp[@]} == 2 && ${sp[0]:-} == t1 && ${sp[1]:-} == n1 ]] \
        || fail "build-tools member t1 must be dispatched before ready n1 (spawn order: ${sp[*]:-none}, want [t1 n1])"

    # The band is dispatch-only: plan/run-record order stays topological
    # build order — a range keeps indexing THAT order.
    order=$(rr_scalar order <<<"$FIXTURE_OUTPUT")
    [[ $order == "n1 t1" ]] \
        || fail "run-record order must stay topological (want [n1 t1], ranges index it), got: $order"
    [[ $(rr_row t1 status <<<"$FIXTURE_OUTPUT") == succeeded ]] \
        || fail "t1 did not succeed: $(rr_row t1 <<<"$FIXTURE_OUTPUT")"
    [[ $(rr_row n1 status <<<"$FIXTURE_OUTPUT") == succeeded ]] \
        || fail "n1 did not succeed: $(rr_row n1 <<<"$FIXTURE_OUTPUT")"
    assert_clean "$ws" "$GSA_STATE_DIR"
)

# ─── 3. The band never violates build-order edges ────────────────────────────
# t1 (build-tools) consumes n1 and is picked first BY THE BAND whenever it is
# ready — but readiness includes n1's completion, so t1 must not even START
# before slow n1 has finished, however the band is implemented.
(
    set -euo pipefail
    ws="$fixture/edges/ws"
    make_workspace "$ws" 2 2 xhigh
    add_package "$ws" n1 "$gsa_meta_any" git
    add_package "$ws" t1 "$gsa_meta_any" git
    set_topology_record "$ws" t1 'core,build-tools' 'n1'
    write_dispatch_stub "$ws"
    stub_sudo "$ws"
    stub_pacman "$ws"

    export PATH="$ws/bin:$PATH"
    export GSA_STATE_DIR="$fixture/edges/state"
    export GSA_CPU_THREADS=24 GSA_MEMORY_GIB=21
    export GSA_FAKE_SPAWN_LOG="$fixture/edges/spawn.log"
    export GSA_FAKE_PACMAN_LOG="$fixture/edges/pacman.log"
    export GSA_FAKE_BUILD_SECONDS=1

    run_builder fish "$ws/build-all.fish" \
        --allow-broken-rustc --no-deps --no-sync --lanes 2 --intensity xhigh n1 t1
    ((FIXTURE_RC == 0)) || fail "the edge run failed (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"

    mapfile -t sp < <(spawn_ids "$GSA_FAKE_SPAWN_LOG")
    [[ ${#sp[@]} == 2 && ${sp[0]:-} == n1 && ${sp[1]:-} == t1 ]] \
        || fail "the band must never violate edges: spawn order ${sp[*]:-none}, want [n1 t1]"
    n1_end=$(stamp "$GSA_FAKE_SPAWN_LOG" END n1)
    t1_start=$(stamp "$GSA_FAKE_SPAWN_LOG" SPAWN t1)
    [[ -n $n1_end && -n $t1_start ]] \
        || fail "spawn log lacks SPAWN/END stamps: $(tr '\n' ' ' <"$GSA_FAKE_SPAWN_LOG")"
    ((t1_start >= n1_end)) \
        || fail "build-tools member t1 started ($t1_start) before its prerequisite n1 finished ($n1_end)"
    [[ $(rr_row t1 status <<<"$FIXTURE_OUTPUT") == succeeded ]] \
        || fail "t1 did not succeed: $(rr_row t1 <<<"$FIXTURE_OUTPUT")"
    assert_clean "$ws" "$GSA_STATE_DIR"
)

# ─── 4. No build-tools member: dispatch order is exactly plan order ─────────
# Three plain packages, deliberately named out of alphabetical/record order.
# One lane keeps every spawn sequential so the log order IS the dispatch
# order. Dry-run and run-record orders must agree with each other and with
# the observed spawn order — sets without the group see no change at all.
(
    set -euo pipefail
    ws="$fixture/plain/ws"
    make_workspace "$ws" 1 2 xhigh
    for id in p1 p2 p3; do
        add_package "$ws" "$id" "$gsa_meta_any" git
    done
    write_dispatch_stub "$ws"
    stub_sudo "$ws"
    stub_pacman "$ws"

    export PATH="$ws/bin:$PATH"
    export GSA_STATE_DIR="$fixture/plain/state"
    export GSA_CPU_THREADS=24 GSA_MEMORY_GIB=21
    export GSA_FAKE_SPAWN_LOG="$fixture/plain/spawn.log"
    export GSA_FAKE_PACMAN_LOG="$fixture/plain/pacman.log"
    export GSA_FAKE_BUILD_SECONDS=0.2

    run_builder fish "$ws/build-all.fish" -n --no-deps --no-sync p2 p1 p3
    ((FIXTURE_RC == 0)) || fail "the plain dry run failed (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    dry=$(printf '%s\n' "$FIXTURE_OUTPUT" | dry_rows | tr '\n' ' ')
    dry=${dry% }
    [[ $(printf '%s\n' "$dry" | tr ' ' '\n' | sort | tr '\n' ' ') == "p1 p2 p3 " ]] \
        || fail "dry run lost a package: [$dry]"

    run_builder fish "$ws/build-all.fish" \
        --allow-broken-rustc --no-deps --no-sync --lanes 1 --intensity xhigh p2 p1 p3
    ((FIXTURE_RC == 0)) || fail "the plain run failed (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"

    order=$(rr_scalar order <<<"$FIXTURE_OUTPUT")
    [[ $order == "$dry" ]] \
        || fail "run-record order [$order] no longer matches the dry-run order [$dry]"
    mapfile -t sp < <(spawn_ids "$GSA_FAKE_SPAWN_LOG")
    spawn=$(printf '%s\n' "${sp[@]:-}" | tr '\n' ' ')
    spawn=${spawn% }
    [[ $spawn == "$dry" ]] \
        || fail "a set with no build-tools members must dispatch in plan order: spawn [$spawn] vs plan [$dry]"
    for id in p1 p2 p3; do
        [[ $(rr_row $id status <<<"$FIXTURE_OUTPUT") == succeeded ]] \
            || fail "$id did not succeed: $(rr_row $id <<<"$FIXTURE_OUTPUT")"
    done
    assert_clean "$ws" "$GSA_STATE_DIR"
)

printf 'scheduler dispatch order fixture: PASS\n'
