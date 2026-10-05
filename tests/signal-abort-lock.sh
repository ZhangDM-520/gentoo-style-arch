#!/usr/bin/env bash
set -uo pipefail

# Signal honesty, transaction-safe lane abort, stale-lock probe, and the
# pacman-mutex shim — one synthetic workspace (2026-09-23 incident):
#   - dispatcher + all six lanes died at 19:34:01 with NO recorded signal;
#   - a signal-killed lane left no result at all → rc=125 "no valid result";
#   - stop_lane_process's 20x TERM + KILL-at-0.5 s blitz re-interrupted
#     pacman's db.lck unlock → stale lock → six installs hard-failed;
#   - makepkg's `-s` dep installs ran pacman outside the builder flock.
#
# Sub-tests:
#   1. --stale-lock-check (contract migrated 2026-10-04, R-F1 — was
#      "idle → removed + STALE warning"): a present lock is NEVER deleted
#      automatically in any classification. Proven idle → STALE + the named
#      `sudo rm -f` operator command, rc 1; a killed scan child (the
#      Ctrl-C-storm shape) and hidden handles (unreadable /proc/PID/fd) →
#      UNKNOWN + uncertainty reason, rc 1, nothing deleted; a live
#      inode-holder (a real process holding the lock open — the probe is
#      name-independent) → HELD + pid/cmd + recovery text, rc 1.
#   2. direct --lane-job: SIGTERM the lane child → honest result line
#      "p1 143 N", process rc 143, "lane child received TERM" in the log.
#   3. full run: SIGTERM the live lane child → dispatcher reports
#      BUILD FAILED (rc=143), never "no valid result"; the run-start shim
#      exists (0755, flock/mutex/pacman/"$@") and the stub makepkg saw
#      PACMAN pointing at it.
#   4. SIGINT/SIGTERM/SIGHUP the dispatcher → dispatcher.log names the
#      signal, the run exits with the SIGNAL's own status (INT 130 / TERM 143
#      / HUP 129 — R-F27, never a flat 130) printing "Build interrupted", the
#      run-record `rc:` scalar carries the same number, exactly ONE TERM
#      reaches the lane pgrp (the old blitz logged 20), no lane survives.
#   5. busy db.lck preflight: -i refused with holder + recovery, lock kept;
#      build-only run warns and builds anyway.
#   6. static: grace constant 30 s, one TERM, KILL strictly after the grace.
#   7. direct shim invocation: stub flock proves "$@" pass-through.
#   8. unknown result-pkg edge (2026-09-26 lane codec): a lane whose package
#      identity never landed writes NO result file (the old code fabricated
#      the identity `unknown`, which put a non-package on the result wire);
#      the encode side refuses an empty pkg, so the lane exits 125 loudly.
#   9. run lock (R-F9): a second concurrent run REFUSES — never queues —
#      naming the holder (`another build already holds this workspace's run
#      lock ...`, `  lock:`, `  holder: pid N started …`, `Nothing is
#      queued`); the lock frees within the holder's one 0.25 s poll after a
#      run ends (normal or interrupted) and the run started right after that
#      free succeeds.
#  10. stale run-lock semantics: the flock, not the file content, is the
#      authority — a lock file naming a dead pid blocks nothing, and after a
#      SIGKILLed dispatcher the holder self-expires within one 0.25 s poll,
#      so a dead holder never blocks the next run.
#  11. lane parent-liveness watchdog (R-F8): SIGKILL the dispatcher mid-build
#      and the lane fish AND the stub makepkg die on their own within seconds
#      (no teardown ran); dispatcher-spawned lanes carry exactly one watcher,
#      direct --lane-job invocations (no marker env) spawn none.
#  12. startup orphan probe (R-F8): a live `--lane-job` referencing this
#      run's logs dir belongs to a dead previous run — the builder stops it
#      (stdout `stopping an orphaned lane of a previous run: pid N`,
#      dispatcher.log `orphan lane: pid=N of a previous run`) and the new run
#      itself succeeds.
#  13. second-signal escalation (R-F15): with a TERM-ignoring stub makepkg
#      and the default 30 s grace, a second signal (INT, sent back-to-back
#      after a first HUP so the kernel cannot coalesce them and the handler
#      order is deterministic) SIGKILL-sweeps the lanes IMMEDIATELY —
#      dispatcher.log gains `is the SECOND signal` and `SIGKILL immediately
#      (second signal)`, the run ends seconds later (it must NOT wait out the
#      30 s grace) with rc 130 and no survivors.
#  14. run-scoped result files + foreign identity (R-F9): a foreign wire line
#      (`pX 0 1`) planted in THIS run's result slot is ignored — the healthy
#      lane is never classified from it or killed; the run succeeds and the
#      run-record row for p1 stays `p1 succeeded N N ok`.
#  15. result-clear refusal (R-F33): a non-empty DIRECTORY in the result slot
#      cannot be cleared → dispatch is refused (`cannot clear a stale lane
#      result — refusing to dispatch p1`, row `p1 failed 1 0
#      result-clear-failed`), the run exits non-zero.
#  16. lane payload gates + `-j` pair normalisation (R-F29/R-F30/R-F31): a
#      control character in the result path is refused BEFORE any work
#      (rc 2, no result file); a pkg id outside the codec charset can never
#      reach the wire (rc 125, `lane result write failed`, no result file);
#      MAKEFLAGS/NINJAFLAGS `-j N` pairs re-export as the lane's `-j1` with
#      no stranded operand token.
#  17. SIGINT during PRE-DISPATCH (R-F27, the latch before dispatch): a
#      signal delivered while the ABI gate is still probing — the stub
#      pacman's `pacman -Q rust-git` gate probe sends exactly ONE SIGINT
#      to the builder itself, at a known point, never a sleep-and-hope ^C
#      race — must abort BEFORE any lane/makepkg is spawned: exit 130 (the
#      signal's own status via gsa_signal_exit_rc), the `Build interrupted`
#      warning, the run-record block rendered with every row `never-started
#      … interrupted-before-start`, the stub makepkg log EMPTY, and
#      dispatcher.log's `Build interrupted (last signal: …, before dispatch)`
#      (the abort-before-dispatch marker). The stub logs the pid it targeted;
#      the fixture matches it against the handler's own `signal: INT
#      received (pid=…)` line — the delivery landed on the process whose
#      handler latched it.
#
# Lock isolation: the PATH-stub `pacman-conf` answers DBPath with a fixture
# directory, so the host's real /var/lib/pacman/db.lck is never probed; the
# stub `find` is the fixture-side oracle for the open-handle scan
# (GSA_FAKE_FIND_SCAN_MODE) and holders are real same-user processes holding
# the lock inode open. The builder gains NO GSA_* test knob
# (it honours exactly the seven variables --help lists); GSA_FAKE_* names are
# consumed by the stubs only.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-signal-fixture.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    printf '%s\n' "$@" >&2
    exit 1
}

make_workspace "$fixture" auto auto xhigh
# Dynamic IgnorePkg registration target — never the host's /etc/pacman.conf.
make_install_conf "$fixture/pacman.conf"
add_package "$fixture" p1
# Phase 17's pre-dispatch ABI gate data — the abi-batch-policy.sh layer-1
# (tag batch) shape exactly: llvm-git is the abi=must anchor (no abi-tagged
# dependency), rust-git its abi=must mandatory member (the llvm-git edge).
# A `--no-deps llvm-git …` selection omits the member, so the gate must
# probe `pacman -Q rust-git` asking whether it is installed — that probe
# is the deterministic SIGINT delivery point the stub pacman owns.
add_package "$fixture" llvm-git
add_package "$fixture" rust-git
set_topology_record "$fixture" llvm-git git '' 'abi=must'
set_topology_record "$fixture" rust-git git 'llvm-git' 'abi=must'

# ── stubs (behaviour driven by GSA_FAKE_* variables the STUBS define) ───────
cat >"$fixture/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
name=$(basename "$PWD")
# Invocation log (phase 17's "nothing was dispatched" oracle: an abort before
# dispatch must leave this file empty).
[[ -n ${GSA_FAKE_MAKEPKG_LOG:-} ]] &&
    printf 'BUILD %s\n' "$name" >>"$GSA_FAKE_MAKEPKG_LOG"
[[ -n ${GSA_FAKE_PACMAN_ENV_LOG:-} ]] &&
    printf '%s\n' "${PACMAN:-}" >>"$GSA_FAKE_PACMAN_ENV_LOG"
if [[ -n ${GSA_FAKE_FLAGS_LOG:-} ]]; then
    # MAKEFLAGS/NINJAFLAGS observation (phase 16): what the lane re-exported
    # actually reaches the build command.
    printf 'MAKEFLAGS=%s\n' "${MAKEFLAGS-}" >>"$GSA_FAKE_FLAGS_LOG"
    printf 'NINJAFLAGS=%s\n' "${NINJAFLAGS-}" >>"$GSA_FAKE_FLAGS_LOG"
fi
if [[ -n ${GSA_FAKE_MARKER_DIR:-} ]]; then
    mkdir -p "$GSA_FAKE_MARKER_DIR"
    touch "$GSA_FAKE_MARKER_DIR/$name"
fi
if [[ -n ${GSA_FAKE_BUILD_SECONDS:-} ]]; then
    # Record every signal receipt (the old 20x TERM blitz would show up as
    # repeated lines) and exit promptly on TERM so a well-behaved teardown
    # never has to reach SIGKILL-after-grace. GSA_FAKE_IGNORE_TERM instead
    # makes the build TERM-proof (phase 13: the second-signal escalation must
    # be the thing that ends it, not the grace).
    if [[ -n ${GSA_FAKE_IGNORE_TERM:-} ]]; then
        trap '' TERM
    else
        trap '[[ -n ${GSA_FAKE_SIGNAL_LOG:-} ]] && printf "TERM\n" >>"$GSA_FAKE_SIGNAL_LOG"; exit 143' TERM
    fi
    trap '[[ -n ${GSA_FAKE_SIGNAL_LOG:-} ]] && printf "INT\n" >>"$GSA_FAKE_SIGNAL_LOG"' INT
    trap '[[ -n ${GSA_FAKE_SIGNAL_LOG:-} ]] && printf "HUP\n" >>"$GSA_FAKE_SIGNAL_LOG"' HUP
    sleep "${GSA_FAKE_BUILD_SECONDS}" &
    wait $!
fi
touch "$PWD/$name-1.0-1-x86_64.pkg.tar.zst"
exit 0
EOF

cat >"$fixture/bin/find" <<'EOF'
#!/usr/bin/env bash
# Open-handle scan oracle: the holder probe's inode-match stage (the find
# invocation carrying -samefile over /proc/*/fd dirs) is simulated by
# GSA_FAKE_FIND_SCAN_MODE (kill = the scan child dies mid-run, the Ctrl-C
# storm shape; blind = a process hides its fds; clean = proven idle). The
# fd-dir listing stage and every other find use fall through to the real
# find.
if [[ -n ${GSA_FAKE_FIND_SCAN_MODE:-} ]]; then
    for a in "$@"; do
        if [[ $a == -samefile ]]; then
            case $GSA_FAKE_FIND_SCAN_MODE in
                clean) exit 0 ;;
                kill) exit 130 ;;
                blind) printf "find: '/proc/1/fd': Permission denied\n" >&2; exit 0 ;;
            esac
        fi
    done
fi
exec /usr/bin/find "$@"
EOF

cat >"$fixture/bin/pacman-conf" <<'EOF'
#!/usr/bin/env bash
# DBPath oracle: fixtures must never probe the host's real
# /var/lib/pacman/db.lck — answer with a fixture directory instead.
if [[ ${1:-} == DBPath ]]; then
    printf '%s\n' "${GSA_FAKE_DB_PATH:-/nonexistent-gsa-db}"
    exit 0
fi
exit 1
EOF

cat >"$fixture/bin/flock" <<'EOF'
#!/usr/bin/env bash
# Shim invocation probe: keep REAL flock semantics, but redirect the baked
# /usr/bin/pacman to the recorder so no real database is ever touched.
args=("$@")
for i in "${!args[@]}"; do
    [[ ${args[i]} == /usr/bin/pacman ]] && args[i]=$GSA_FAKE_STUB_PACMAN
done
exec /usr/bin/flock "${args[@]}"
EOF

cat >"$fixture/bin/record-pacman" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GSA_FAKE_STUB_PACMAN_LOG"
exit 0
EOF

cat >"$fixture/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -u
# Pre-dispatch ABI-gate probe stub + the deterministic SIGINT trigger (phase
# 17). The builder's gate probe arrives `pacman -Q NAME`; other probes may
# pass `--` before names, so a leading `--` is dropped before reading.
# `-Q NAME` answers "installed" exactly for the names in GSA_FAKE_INSTALLED.
# When GSA_FAKE_INT_QUERY names the probed package, this stub sends exactly
# ONE SIGINT to the BUILDER (the atomic mkdir guard makes even a repeated
# probe a no-op — a second signal would escalate to the SIGKILL sweep) and
# records the pid it targeted in GSA_FAKE_INT_TRIGGER_LOG so the fixture can
# prove the delivery landed on the very process whose handler latched it.
# The target is found by walking up from $PPID to the build-all.fish ancestor
# (fish execs this stub directly, so $PPID is normally already fish) — the
# walk never leaves THIS run's process chain, so a sibling fixture running in
# parallel can never be signalled.
[[ -n ${GSA_FAKE_PACMAN_LOG:-} ]] &&
    printf 'pacman %s\n' "$*" >>"$GSA_FAKE_PACMAN_LOG"
args=()
for a in "$@"; do
    [[ $a == -- ]] && continue
    args+=("$a")
done
name=${args[1]:-}
if [[ ${args[0]:-} == -Q && -n ${GSA_FAKE_INT_QUERY:-} &&
    $name == "$GSA_FAKE_INT_QUERY" ]] &&
    mkdir "${GSA_FAKE_INT_TRIGGER_DIR:?INT trigger needs GSA_FAKE_INT_TRIGGER_DIR}" 2>/dev/null; then
    target=$PPID
    found=
    for _ in 1 2 3 4 5 6; do
        [[ -r /proc/$target/cmdline ]] || break
        if tr '\0' ' ' <"/proc/$target/cmdline" | grep -q 'build-all\.fish'; then
            found=1
            break
        fi
        target=$(awk '/^PPid:/ {print $2}' "/proc/$target/status" 2>/dev/null)
        [[ -n ${target:-} ]] || break
    done
    if [[ -z $found ]]; then
        printf 'trigger failed: no build-all.fish ancestor (ppid=%s)\n' "$PPID" \
            >>"${GSA_FAKE_INT_TRIGGER_LOG:?INT trigger needs GSA_FAKE_INT_TRIGGER_LOG}"
        exit 97
    fi
    printf 'trigger: argv=pacman %s stub=%s ppid=%s target=%s\n' \
        "$*" "$$" "$PPID" "$target" >>"$GSA_FAKE_INT_TRIGGER_LOG"
    command kill -INT "$target"
fi
if [[ ${args[0]:-} == -Q ]]; then
    for installed in ${GSA_FAKE_INSTALLED:-}; do
        [[ $installed == "$name" ]] && exit 0
    done
fi
exit 1
EOF

chmod +x "$fixture/bin/"*

BARGS=(--allow-broken-rustc --no-deps --no-sync --lanes 1 --jobs 1 p1)
RUN_ENV=()
disp=""
wd=""

mk_env() { # state build_seconds
    local state=$1 secs=$2
    mkdir -p "$state"
    RUN_ENV=(
        "PATH=$fixture/bin:$PATH"
        "GSA_STATE_DIR=$state"
        "_IGNOREPKG_CONF=$fixture/pacman.conf"
        "GSA_FAKE_DB_PATH=$state/var/pacman"
        "GSA_FAKE_MARKER_DIR=$state/built"
        "GSA_FAKE_PACMAN_ENV_LOG=$state/pacman-env.log"
        "GSA_FAKE_SIGNAL_LOG=$state/signals.log"
        "GSA_FAKE_BUILD_SECONDS=$secs"
    )
}

wait_for_file() { # path [timeout-s]
    local f=$1 t=${2:-10} i
    for ((i = 0; i < t * 10; i++)); do
        [[ -e $f ]] && return 0
        sleep 0.1
    done
    return 1
}

run_bg() { # out-file cmd...   → sets $disp/$wd
    local out=$1; shift
    env "${RUN_ENV[@]}" "$@" >"$out" 2>&1 &
    disp=$!
    ( for ((i = 0; i < 800; i++)); do
          command kill -0 "$disp" 2>/dev/null || exit 0
          sleep 0.1
      done
      command kill -KILL "$disp" 2>/dev/null ) &
    wd=$!
}

end_bg() { # wait for $disp → $rc; reap the watchdog
    wait "$disp" 2>/dev/null
    rc=$?
    command kill "$wd" 2>/dev/null || true
    wait "$wd" 2>/dev/null || true
}

find_lane_pid() {
    # Scoped to THIS fixture's synthetic workspace. The battery runs fixtures in
    # parallel, so a global `--lane-job` match would pick a sibling fixture's
    # lane (the 2026-09-24 "never run two batteries at once" hazard, which a
    # parallel runner would otherwise self-inflict on every run). Lane argv
    # always carries the builder's own path: `fish $SCRIPT_DIR/build-all.fish
    # --lane-job …`, and SCRIPT_DIR lives under $fixture here.
    ps -eo pid=,args= | awk -v f="$fixture" \
        '/build-all\.fish --lane-job/ && index($0, f) && !/awk/ {print $1; exit}'
}

wait_for_text() { # file text [timeout-s]
    local f=$1 txt=$2 t=${3:-10} i
    for ((i = 0; i < t * 10; i++)); do
        grep -qF -- "$txt" "$f" 2>/dev/null && return 0
        sleep 0.1
    done
    return 1
}

watchers_under() { # parent-pid → watchdog sh pids spawned by that process
    # The R-F8 lane watchdog is `sh -c '<script>' sh <pid> <pgid> <lane>` with
    # the literal line `kill -TERM -- "-$2"` in its argv. Scoped by PPid (the
    # watcher is a DIRECT child of the lane fish) so a sibling fixture's
    # watcher is never counted; /proc cmdline is NUL-separated, hence -a.
    local parent=$1 d pid
    for d in /proc/[0-9]*; do
        pid=${d#/proc/}
        [[ -r $d/cmdline ]] || continue
        [[ $(awk '/^PPid:/ {print $2}' "$d/status" 2>/dev/null) == "$parent" ]] ||
            continue
        grep -qaF 'kill -TERM -- "-$2"' "$d/cmdline" 2>/dev/null && printf '%s\n' "$pid"
    done
    return 0
}

fixture_lives() {
    # Any process of THIS fixture still alive (survivor probe — same scoping
    # rule as find_lane_pid). The lane watchdog's argv is pid numbers only, so
    # it cannot match here by construction.
    ps -eo pid=,args= | grep -F "$fixture" | grep -v grep
}

# ── 6. static shape of stop_lane_process (do NOT wait out the real 30 s) ────
gf="$root/build-all.fish"
# The default must still be 30 — the value lives behind the env-override seam
# (tests/dashboard.sh shortens it to prove the KILL path fast), so pin both
# halves: the 30 fallback and the seam that may replace it.
grace=$(sed -n 's/^[[:space:]]*set -g _LANE_STOP_GRACE_S \([0-9][0-9]*\)$/\1/p' "$gf" |
    head -1)
[[ $grace == 30 ]] ||
    fail "grace default must be 30 s (got '$grace')"
grep -qF 'if not set -q _LANE_STOP_GRACE_S; or not string match -qr' "$gf" ||
    fail "_LANE_STOP_GRACE_S must stay an env-overridable internal seam"
stop_body=$(sed -n '/^function stop_lane_process/,/^function cleanup_active_lanes/p' "$gf")
[[ -n $stop_body ]] || fail "could not extract stop_lane_process from build-all.fish"
term_lines=$(grep -c 'kill -TERM' <<<"$stop_body")
[[ $term_lines -eq 1 ]] ||
    fail "stop_lane_process must issue exactly ONE TERM sweep (found $term_lines)"
grep -q 'sleep 0.1' <<<"$stop_body" ||
    fail "stop_lane_process must poll at 0.1 s granularity"
grep -q 'SIGKILL after grace' <<<"$stop_body" ||
    fail "escalation after grace must be logged as 'SIGKILL after grace'"
grep -q '\[DEBUG-gsa-term\]' "$gf" ||
    fail "missing [DEBUG-gsa-term] forensics tag"
term_line=$(grep -n 'kill -TERM' <<<"$stop_body" | head -1 | cut -d: -f1)
grace_line=$(grep -n 'grace_deadline' <<<"$stop_body" | head -1 | cut -d: -f1)
kill_line=$(grep -n 'kill -KILL' <<<"$stop_body" | head -1 | cut -d: -f1)
[[ -n $term_line && -n $grace_line && -n $kill_line ]] ||
    fail "could not locate TERM/grace/KILL lines in stop_lane_process"
(( term_line < grace_line && grace_line < kill_line )) ||
    fail "SIGKILL must come strictly after the grace window"

# ── 1. hidden --stale-lock-check against fixture lock paths ────────────────
echo "phase 1: stale-lock probe (report-only: never deleted automatically)"
idle_lock="$fixture/idle.lck"
: >"$idle_lock"
idle_out="$fixture/phase1-idle.out"
env PATH="$fixture/bin:$PATH" GSA_FAKE_DB_PATH="$fixture/var/pacman" \
    GSA_FAKE_FIND_SCAN_MODE=clean \
    fish "$fixture/build-all.fish" --stale-lock-check "$idle_lock" >"$idle_out" 2>&1
p1_rc=$?
[[ $p1_rc -eq 1 ]] ||
    fail "idle lock check rc=$p1_rc, want 1 (a present lock is never clear-to-install)" "$(cat "$idle_out")"
[[ -e $idle_lock ]] ||
    fail "idle (holder-less) lock was DELETED — the builder must never delete a system lock"
grep -q 'status: STALE' "$idle_out" ||
    fail "stub-proven-idle lock not classified STALE:" "$(cat "$idle_out")"
grep -q 'NEVER deleted automatically' "$idle_out" ||
    fail "stale report lacks the never-delete contract line:" "$(cat "$idle_out")"
grep -q 'sudo rm -f' "$idle_out" ||
    fail "stale report lacks the operator removal command:" "$(cat "$idle_out")"
grep -qF "$idle_lock" "$idle_out" ||
    fail "stale report does not name the lock path"

# Real-scan pass: the classification is host-dependent (root processes hide
# their fds from a user), the invariants are not.
idle_out2="$fixture/phase1-idle-real.out"
env PATH="$fixture/bin:$PATH" GSA_FAKE_DB_PATH="$fixture/var/pacman" \
    fish "$fixture/build-all.fish" --stale-lock-check "$idle_lock" >"$idle_out2" 2>&1
p1_rc=$?
[[ $p1_rc -eq 1 ]] || fail "real-scan idle check rc=$p1_rc, want 1" "$(cat "$idle_out2")"
[[ -e $idle_lock ]] || fail "real-scan pass DELETED the lock"
grep -q 'NEVER deleted automatically' "$idle_out2" ||
    fail "real-scan report lacks the never-delete contract line:" "$(cat "$idle_out2")"

# Ctrl-C-storm shape: the scan child dies mid-run (rc>=128) — the probe must
# classify UNKNOWN, never proven idle, and delete nothing.
storm_out="$fixture/phase1-storm.out"
env PATH="$fixture/bin:$PATH" GSA_FAKE_DB_PATH="$fixture/var/pacman" \
    GSA_FAKE_FIND_SCAN_MODE=kill \
    fish "$fixture/build-all.fish" --stale-lock-check "$idle_lock" >"$storm_out" 2>&1
p1_rc=$?
[[ $p1_rc -eq 1 ]] || fail "killed-probe check rc=$p1_rc, want 1" "$(cat "$storm_out")"
[[ -e $idle_lock ]] || fail "killed probe DELETED the lock"
grep -q 'status: UNKNOWN' "$storm_out" ||
    fail "killed probe did not classify UNKNOWN:" "$(cat "$storm_out")"
grep -q 'cannot prove' "$storm_out" ||
    fail "killed probe report lacks the uncertainty reason:" "$(cat "$storm_out")"

# Hidden handles (an unreadable /proc/PID/fd — a foreign-root alpm client)
# are UNKNOWN too, never proven idle.
blind_out="$fixture/phase1-blind.out"
env PATH="$fixture/bin:$PATH" GSA_FAKE_DB_PATH="$fixture/var/pacman" \
    GSA_FAKE_FIND_SCAN_MODE=blind \
    fish "$fixture/build-all.fish" --stale-lock-check "$idle_lock" >"$blind_out" 2>&1
p1_rc=$?
[[ $p1_rc -eq 1 ]] || fail "blind-probe check rc=$p1_rc, want 1" "$(cat "$blind_out")"
[[ -e $idle_lock ]] || fail "blind probe DELETED the lock"
grep -q 'status: UNKNOWN' "$blind_out" ||
    fail "blind probe did not classify UNKNOWN:" "$(cat "$blind_out")"

# A live inode-holder (any process holding the lock open — no name list) is
# detected and classified HELD.
busy_lock="$fixture/busy.lck"
: >"$busy_lock"
sleep 60 60<"$busy_lock" &
holder=$!
busy_out="$fixture/phase1-busy.out"
env PATH="$fixture/bin:$PATH" GSA_FAKE_DB_PATH="$fixture/var/pacman" \
    fish "$fixture/build-all.fish" --stale-lock-check "$busy_lock" >"$busy_out" 2>&1
p1b_rc=$?
[[ $p1b_rc -eq 1 ]] ||
    fail "busy lock check rc=$p1b_rc, want 1" "$(cat "$busy_out")"
[[ -e $busy_lock ]] ||
    fail "lock with a live holder was REMOVED"
grep -q "holder pid=$holder" "$busy_out" ||
    fail "holder pid not reported:" "$(cat "$busy_out")"
grep -q 'cmd=.*sleep' "$busy_out" ||
    fail "holder cmdline not reported:" "$(cat "$busy_out")"
grep -q 'status: HELD' "$busy_out" ||
    fail "live holder was not classified HELD:" "$(cat "$busy_out")"
grep -q 'Recovery:' "$busy_out" ||
    fail "no recovery instructions for a held lock"
grep -qF "$busy_lock" "$busy_out" ||
    fail "busy report does not name the lock path"
command kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null

# ── 2. direct --lane-job: honest result file + process rc on SIGTERM ───────
echo "phase 2: SIGTERM the lane child directly"
state="$fixture/state-lane"
mk_env "$state" 1.5
res="$state/logs/.lane-direct.result"
run_bg "$state/lane.out" fish "$fixture/build-all.fish" \
    --lane-job p1 "$res" 1 0 0 0 1 0
lane=$disp
wait_for_file "$state/built/p1" 10 ||
    fail "stub makepkg never started (lane did not reach the build)" \
        "$(cat "$state/lane.out")"
command kill -TERM "$lane"
end_bg
[[ $rc -eq 143 ]] ||
    fail "signal-exited lane child rc=$rc, want honest 143" "$(cat "$state/lane.out")"
[[ -s $res ]] ||
    fail "no result file after lane SIGTERM" "$(cat "$state/lane.out")"
grep -Eq '^p1 143 [0-9]+$' "$res" ||
    fail "result file not honest: '$(cat "$res")' (want 'p1 143 <secs>')"
grep -q 'lane child received TERM' "$state/logs/p1.log" ||
    fail "package log missing 'lane child received TERM'" "$(cat "$state/logs/p1.log" 2>/dev/null)"

# ── 3. full run: dispatcher sees an honest 143, never rc=125 ───────────────
echo "phase 3: SIGTERM the live lane child under a dispatcher"
state="$fixture/state-full"
mk_env "$state" 3
run_bg "$state/run.out" fish "$fixture/build-all.fish" "${BARGS[@]}"
wait_for_file "$state/built/p1" 15 ||
    fail "lane never started in the full run" "$(cat "$state/run.out")"
lane=$(find_lane_pid)
[[ -n $lane ]] ||
    fail "no --lane-child process found for the SIGTERM"
command kill -TERM "$lane"
end_bg
[[ $rc -ne 0 ]] ||
    fail "run with a signal-killed lane reported success" "$(cat "$state/run.out")"
grep -q 'BUILD FAILED (rc=143' "$state/run.out" ||
    fail "dispatcher did not report the honest 143" "$(cat "$state/run.out")"
if grep -q 'no valid result' "$state/run.out"; then
    fail "dispatcher fell back to 'no valid result'" "$(cat "$state/run.out")"
fi
grep -q 'lane child received TERM' "$state/logs/p1.log" ||
    fail "package log missing 'lane child received TERM' after full run"
# R-F27 row reasons: the lane's honest 143 is CLASSIFIED on the row — the
# signal's own name, not a generic build-failed.
row=$(rr_row p1 <"$state/run.out") ||
    fail "no run-record row for p1" "$(cat "$state/run.out")"
[[ $row =~ ^p1\ failed\ 143\ [0-9]+\ signal-term$ ]] ||
    fail "run-record row for the signalled lane is '$row', want 'p1 failed 143 <secs> signal-term' (R-F27 row reason)"

shim="$state/logs/.pacman-shim"
[[ -e $shim ]] ||
    fail "run start did not generate $shim"
[[ $(stat -c %a "$shim") == 755 ]] ||
    fail "shim mode is $(stat -c %a "$shim"), want 755"
grep -q 'flock -x -w 300' "$shim" ||
    fail "shim lacks 'flock -x -w 300': $(cat "$shim")"
grep -qF "$state/logs/.pacman-install.lock" "$shim" ||
    fail "shim lacks the absolute mutex path: $(cat "$shim")"
grep -q '/usr/bin/pacman' "$shim" ||
    fail "shim lacks /usr/bin/pacman: $(cat "$shim")"
grep -qF '"$@"' "$shim" ||
    fail "shim does not pass through \"\$@\": $(cat "$shim")"
[[ -f $state/pacman-env.log ]] ||
    fail "stub makepkg never observed its environment"
grep -qxF "$shim" "$state/pacman-env.log" ||
    fail "PACMAN did not point at the shim: $(cat "$state/pacman-env.log")"

# ── 4. dispatcher forensics for INT / TERM / HUP ───────────────────────────
# R-F27: the interrupted run exits with the SIGNAL's own status — never a flat
# 130 — and the run-record `rc:` scalar shows the same number.
declare -A sig_rc=([INT]=130 [TERM]=143 [HUP]=129)
for sig in INT TERM HUP; do
    echo "phase 4: SIG$sig the dispatcher"
    state="$fixture/state-dispatch-$sig"
    mk_env "$state" 4
    run_bg "$state/run.out" fish "$fixture/build-all.fish" "${BARGS[@]}"
    wait_for_file "$state/built/p1" 15 ||
        fail "$sig: lane never started" "$(cat "$state/run.out")"
    command kill -s "$sig" "$disp"
    end_bg
    [[ $rc -eq ${sig_rc[$sig]} ]] ||
        fail "$sig: dispatcher run exited rc=$rc, want ${sig_rc[$sig]} (the signal's own status)" \
            "$(cat "$state/run.out")"
    rr_rc=$(rr_scalar rc <"$state/run.out") ||
        fail "$sig: no run record in the interrupted run" "$(cat "$state/run.out")"
    [[ $rr_rc == "${sig_rc[$sig]}" ]] ||
        fail "$sig: run-record rc: $rr_rc, want ${sig_rc[$sig]}"
    grep -q 'Build interrupted' "$state/run.out" ||
        fail "$sig: no 'Build interrupted' message" "$(cat "$state/run.out")"
    dlog="$state/logs/dispatcher.log"
    [[ -f $dlog ]] ||
        fail "$sig: dispatcher.log was never created"
    grep -q "signal: $sig received" "$dlog" ||
        fail "$sig: dispatcher.log does not name the signal:" "$(cat "$dlog")"
    grep -q '\[DEBUG-gsa-term\]' "$dlog" ||
        fail "$sig: dispatcher.log lines lack the [DEBUG-gsa-term] tag"
    grep -q 'Build interrupted' "$dlog" ||
        fail "$sig: permanent 'Build interrupted' event missing from dispatcher.log"
    grep -q 'cleanup begin' "$dlog" ||
        fail "$sig: cleanup_active_lanes left no forensics trail"
    # exactly ONE TERM per lane pgrp (the removed blitz sent 20 in 0.5 s),
    # and the lane exits on it fast — no SIGKILL escalation ever happens.
    [[ -f $state/signals.log ]] ||
        fail "$sig: the lane pgrp received no TERM during teardown"
    term_count=$(grep -c '^TERM$' "$state/signals.log")
    [[ $term_count -eq 1 ]] ||
        fail "$sig: lane pgrp received $term_count TERMs, want exactly 1" \
            "$(cat "$state/signals.log")"
    sleep 0.3
    # Scoped to $fixture for the same reason as find_lane_pid: a sibling
    # fixture's lane running concurrently must not be read as a survivor.
    if ps -eo args= | grep -F 'build-all.fish --lane-job' | grep -F "$fixture" |
        grep -v grep >/dev/null; then
        fail "$sig: a lane process survived the dispatcher:" \
            "$(ps -eo pid=,args= | grep -F 'build-all.fish --lane-job' |
            grep -F "$fixture" | grep -v grep)"
    fi
    if ps -eo args= | grep -F "$fixture/bin/makepkg" | grep -v grep >/dev/null; then
        fail "$sig: a stub makepkg survived the dispatcher"
    fi
done

# ── 5. preflight: busy lock refuses -i, warns but builds build-only ────────
echo "phase 5: busy db.lck preflight"
state="$fixture/state-preflight"
mkdir -p "$state/var/pacman"
lock="$state/var/pacman/db.lck"
: >"$lock"
sleep 60 60<"$lock" &
holder=$!
mk_env "$state" 0.5
run_bg "$state/i.out" fish "$fixture/build-all.fish" \
    --allow-broken-rustc --no-deps --no-sync --lanes 1 --jobs 1 --install p1
end_bg
[[ $rc -ne 0 ]] ||
    fail "-i run over a busy lock was not refused" "$(cat "$state/i.out")"
grep -q 'refusing to start an -i run' "$state/i.out" ||
    fail "no refusal message for busy lock:" "$(cat "$state/i.out")"
grep -q "holder pid=$holder" "$state/i.out" ||
    fail "refusal does not report the holder:" "$(cat "$state/i.out")"
grep -q 'Recovery:' "$state/i.out" ||
    fail "refusal lacks recovery instructions:" "$(cat "$state/i.out")"
grep -qF "$lock" "$state/i.out" ||
    fail "refusal does not name the lock path:" "$(cat "$state/i.out")"
[[ -e $lock ]] ||
    fail "busy lock was removed by the refused -i run"
[[ ! -d $state/built ]] ||
    fail "lanes dispatched despite the refused -i run"

mk_env "$state" 0.5
run_bg "$state/build.out" fish "$fixture/build-all.fish" "${BARGS[@]}"
end_bg
[[ $rc -eq 0 ]] ||
    fail "build-only run over a busy lock failed" "$(cat "$state/build.out")"
grep -q 'building anyway' "$state/build.out" ||
    fail "build-only run did not warn about the busy lock" "$(cat "$state/build.out")"
grep -q "holder pid=$holder" "$state/build.out" ||
    fail "build-only warning does not report the holder" "$(cat "$state/build.out")"
[[ -e $lock ]] ||
    fail "build-only preflight removed a held lock"
command kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null

# ── 7. direct shim invocation: "$@" reaches pacman untouched ───────────────
echo "phase 7: invoke the shim directly"
stub_log="$fixture/stub-pacman.log"
: >"$stub_log"
env PATH="$fixture/bin:$PATH" \
    GSA_FAKE_STUB_PACMAN="$fixture/bin/record-pacman" \
    GSA_FAKE_STUB_PACMAN_LOG="$stub_log" \
    "$shim" --frobnicate 'arg with space' 'wild*card' ||
    fail "shim invocation failed"
[[ $(cat "$stub_log") == '--frobnicate arg with space wild*card' ]] ||
    fail "shim did not pass \$@ through verbatim: '$(cat "$stub_log")'"

# ── 8. unknown result-pkg edge: identity-less lane writes NOTHING ──────────
# gsa_handle_signal used to fabricate a result identity `unknown` when the
# signal arrived before the pkg was known — a non-package on the result wire
# that the reap's identity check could not honestly classify. Now it writes
# nothing (the dispatcher classifies the missing result as lane-lost and names
# the lane). The codec's encode side enforces the same identity rule — an
# empty pkg can never reach the wire — so the lane's result write fails loudly
# and the process exits lane_outcome_lost (125), not some silent zero.
echo "phase 8: identity-less lane result writes nothing"
state="$fixture/state-unknown"
mk_env "$state" 0.5
mkdir -p "$state/logs"
res="$state/logs/.lane-unknown.result"
rc=0
env "${RUN_ENV[@]}" fish "$fixture/build-all.fish" \
    --lane-job "" "$res" 1 0 0 0 1 0 >"$state/unknown.out" 2>&1 || rc=$?
[[ $rc -eq 125 ]] ||
    fail "empty-pkg --lane-job rc=$rc, want 125 (lane_outcome_lost)" \
        "$(cat "$state/unknown.out")"
grep -q 'lane result write failed' "$state/unknown.out" ||
    fail "no loud result-write failure for the identity-less lane:" \
        "$(cat "$state/unknown.out")"
[[ ! -e $res ]] ||
    fail "identity-less lane published a result file: '$(cat "$res")'"
grep -qF 'write_lane_result "$_LANE_JOB_RESULT" unknown' "$gf" &&
    fail "gsa_handle_signal still fabricates an 'unknown' result identity"

if ps -eo args= | grep -F "$fixture" | grep -v grep >/dev/null; then
    fail "a fixture process survived:" \
        "$(ps -eo args= | grep -F "$fixture" | grep -v grep)"
fi

# ── 9. run lock: a second run refuses, a finished run releases ─────────────
echo "phase 9: workspace run lock (refuse, never queue; released after a run)"
state="$fixture/state-lock"
mk_env "$state" 20
run_bg "$state/a.out" fish "$fixture/build-all.fish" "${BARGS[@]}"
lock_a=$disp
wait_for_file "$state/built/p1" 15 ||
    fail "lock run A never started building" "$(cat "$state/a.out")"
rc_b=0
env "${RUN_ENV[@]}" fish "$fixture/build-all.fish" "${BARGS[@]}" \
    >"$state/b.out" 2>&1 || rc_b=$?
[[ $rc_b -ne 0 ]] ||
    fail "second concurrent run was not refused (rc=$rc_b)" "$(cat "$state/b.out")"
grep -qF "another build already holds this workspace's run lock — refusing to run concurrently" \
    "$state/b.out" ||
    fail "refusal message missing:" "$(cat "$state/b.out")"
grep -qF "lock: $state/run.lock" "$state/b.out" ||
    fail "refusal does not name the lock path:" "$(cat "$state/b.out")"
grep -qF "holder: pid $lock_a started" "$state/b.out" ||
    fail "refusal does not name the live holder (pid $lock_a):" "$(cat "$state/b.out")"
grep -qF 'Nothing is queued' "$state/b.out" ||
    fail "refusal lacks 'Nothing is queued':" "$(cat "$state/b.out")"
command kill -TERM "$lock_a"
end_bg
# The holder dies with its dispatcher within one 0.25 s poll (it watches the
# dispatcher pid), so an ended run never blocks the next one. Observe the
# free through that bound — then the next run must proceed.
lock_free=1
for ((i = 0; i < 10; i++)); do
    /usr/bin/flock -n "$state/run.lock" true 2>/dev/null && {
        lock_free=0
        break
    }
    sleep 0.1
done
[[ $lock_free -eq 0 ]] ||
    fail "run lock still held 1 s after its run ended"

# After a normal run the lock is released: the run started right after it
# frees must succeed and must not print the refusal.
mk_env "$state" 0.5
run_bg "$state/c.out" fish "$fixture/build-all.fish" "${BARGS[@]}"
end_bg
[[ $rc -eq 0 ]] ||
    fail "normal run after the refused probe failed: rc=$rc" "$(cat "$state/c.out")"
lock_free=1
for ((i = 0; i < 10; i++)); do
    /usr/bin/flock -n "$state/run.lock" true 2>/dev/null && {
        lock_free=0
        break
    }
    sleep 0.1
done
[[ $lock_free -eq 0 ]] ||
    fail "run lock not released within 1 s after a NORMAL run ended"
run_bg "$state/d.out" fish "$fixture/build-all.fish" "${BARGS[@]}"
end_bg
[[ $rc -eq 0 ]] ||
    fail "the run started right after the release failed: rc=$rc" \
        "$(cat "$state/d.out")"
if grep -q 'refusing to run concurrently' "$state/d.out"; then
    fail "the run started right after a normal run was refused the lock:" \
        "$(cat "$state/d.out")"
fi

# ── 10. stale run lock: the flock is the authority, not the file content ───
echo "phase 10: stale run-lock semantics (dead holder never blocks)"
state="$fixture/state-stale-lock"
mkdir -p "$state"
# (a) a lock FILE naming a dead pid must block nothing — the flock is the
#     authority, the content is only ever a naming hint.
printf 'pid 4194000 started 2020-01-01T00:00:00+0000\n' >"$state/run.lock"
mk_env "$state" 0.5
run_bg "$state/a.out" fish "$fixture/build-all.fish" "${BARGS[@]}"
end_bg
[[ $rc -eq 0 ]] ||
    fail "run over a stale lock file (dead-pid content) failed: rc=$rc" \
        "$(cat "$state/a.out")"
if grep -q 'refusing to run concurrently' "$state/a.out"; then
    fail "stale lock-file content blocked the run:" "$(cat "$state/a.out")"
fi
# (b) a SIGKILLed dispatcher's holder self-expires within one 0.25 s poll —
#     the lock frees and the next run proceeds.
mk_env "$state" 20
run_bg "$state/b.out" fish "$fixture/build-all.fish" "${BARGS[@]}"
wait_for_file "$state/built/p1" 15 ||
    fail "lock run B never started building" "$(cat "$state/b.out")"
command kill -KILL "$disp"
end_bg
for ((i = 0; i < 50; i++)); do
    /usr/bin/flock -n "$state/run.lock" true 2>/dev/null && break
    sleep 0.1
done
/usr/bin/flock -n "$state/run.lock" true 2>/dev/null ||
    fail "run lock still held 5 s after its dispatcher was SIGKILLed"
mk_env "$state" 1
run_bg "$state/c.out" fish "$fixture/build-all.fish" "${BARGS[@]}"
end_bg
[[ $rc -eq 0 ]] ||
    fail "run after a dead holder failed: rc=$rc" "$(cat "$state/c.out")"
if grep -q 'refusing to run concurrently' "$state/c.out"; then
    fail "a dead holder blocked the next run:" "$(cat "$state/c.out")"
fi

# ── 11. lane parent-liveness watchdog: dead dispatcher ⇒ the lane dies ─────
echo "phase 11: lane parent-liveness watchdog"
state="$fixture/state-watchdog"
mk_env "$state" 30
run_bg "$state/run.out" fish "$fixture/build-all.fish" "${BARGS[@]}"
wait_for_file "$state/built/p1" 15 ||
    fail "watchdog run never started building" "$(cat "$state/run.out")"
lane=$(find_lane_pid)
[[ -n $lane ]] || fail "no lane process to watch"
[[ -n $(watchers_under "$lane") ]] ||
    fail "dispatcher-spawned lane spawned no parent-liveness watcher"
command kill -KILL "$disp"
end_bg
t0=$(date +%s)
watchdog_ok=1
for ((i = 0; i < 150; i++)); do
    if [[ -z $(find_lane_pid) ]] &&
        ! ps -eo args= | grep -F "$fixture/bin/makepkg" | grep -v grep >/dev/null; then
        watchdog_ok=0
        break
    fi
    sleep 0.1
done
elapsed=$(( $(date +%s) - t0 ))
[[ $watchdog_ok -eq 0 ]] ||
    fail "lane/stub makepkg survived ${elapsed}s after the dispatcher SIGKILL" \
        "$(ps -eo pid=,args= | grep -F "$fixture" | grep -v grep)"
[[ $elapsed -le 12 ]] ||
    fail "watchdog teardown took ${elapsed}s, want well under ~8s"
grep -q 'cleanup begin' "$state/logs/dispatcher.log" 2>/dev/null &&
    fail "builder teardown ran after the dispatcher SIGKILL — the lane must die unassisted"
grep -q 'Build interrupted' "$state/run.out" &&
    fail "a SIGKILLed dispatcher printed 'Build interrupted'" \
        "$(cat "$state/run.out")"

# Direct --lane-job seam invocations carry no marker env and spawn NO watcher.
mk_env "$state" 2
run_bg "$state/direct.out" fish "$fixture/build-all.fish" \
    --lane-job p1 "$state/logs/.lane-direct.result" 1 0 0 0 1 0
lane=$disp
wait_for_file "$state/built/p1" 10 ||
    fail "direct lane never started" "$(cat "$state/direct.out")"
[[ -z $(watchers_under "$lane") ]] ||
    fail "a direct --lane-job (no marker env) spawned a watcher"
end_bg

# ── 12. startup orphan probe: a dead run's lane is stopped ─────────────────
echo "phase 12: startup orphan probe"
state="$fixture/state-orphan"
mk_env "$state" 30
mkdir -p "$state/logs"
# The orphan must own its own process GROUP: stop_lane_process reads the lane
# pid as a pgid (a plain background job would share THIS script's pgrp and the
# sweep would TERM the fixture itself), so setsid reproduces how a real
# dispatcher-spawned lane looks after its dispatcher died.
setsid env "${RUN_ENV[@]}" fish "$fixture/build-all.fish" \
    --lane-job p1 "$state/logs/.lane-orphan.result" 1 0 0 0 1 0 \
    >"$state/orphan.out" 2>&1 &
orph_wait=$!
wait_for_file "$state/built/p1" 15 ||
    fail "orphan lane's stub makepkg never started" "$(cat "$state/orphan.out")"
orph=$(find_lane_pid)
[[ -n $orph ]] || fail "could not identify the orphan lane"
mk_env "$state" 0.5
run_bg "$state/run.out" fish "$fixture/build-all.fish" "${BARGS[@]}"
end_bg
[[ $rc -eq 0 ]] ||
    fail "run over an orphaned lane of a previous run failed: rc=$rc" \
        "$(cat "$state/run.out")"
grep -qF "stopping an orphaned lane of a previous run: pid $orph" "$state/run.out" ||
    fail "no named orphan-stop warning (pid $orph):" "$(cat "$state/run.out")"
grep -qF "orphan lane: pid=$orph of a previous run" "$state/logs/dispatcher.log" ||
    fail "dispatcher.log lacks the orphan-stop line:" \
        "$(cat "$state/logs/dispatcher.log" 2>/dev/null)"
orph_gone=1
for ((i = 0; i < 150; i++)); do
    orph_state=$(ps -o stat= -p "$orph" 2>/dev/null)
    if [[ -z $orph_state || $orph_state == *Z* ]]; then
        orph_gone=0
        break
    fi
    sleep 0.1
done
[[ $orph_gone -eq 0 ]] ||
    fail "orphan lane $orph survived the sweep" \
        "$(ps -eo pid=,args= | grep -F "$fixture" | grep -v grep)"
wait "$orph_wait" 2>/dev/null

# ── 13. second-signal escalation: SIGKILL sweep, grace skipped ─────────────
echo "phase 13: second-signal escalation (TERM-ignoring lane, 30 s grace)"
state="$fixture/state-escalate"
mk_env "$state" 60
RUN_ENV+=("GSA_FAKE_IGNORE_TERM=1")
run_bg "$state/run.out" fish "$fixture/build-all.fish" "${BARGS[@]}"
wait_for_file "$state/built/p1" 15 ||
    fail "escalation run never started building" "$(cat "$state/run.out")"
lane=$(find_lane_pid)
[[ -n $lane ]] || fail "no lane process for the escalation test"
t0=$(date +%s)
# The first signal (HUP) latches the interrupt and starts the normal
# TERM→grace→KILL teardown — the lane IGNORES TERM, so without escalation the
# run would wait out the whole 30 s grace. The SECOND signal (INT) says NOW:
# it must SIGKILL-sweep immediately, and it must be the LAST handler to run so
# _LAST_SIGNAL=INT (rc 130). Both are sent back-to-back so the two handlers
# run in the same interrupt window (a second signal arriving later lands
# after cleanup has emptied the active-lane list and the sweep is a no-op —
# measured: 30 ms+ spacing waits out the grace). The HUP→INT ORDER is the one
# pairing both delivery mechanisms agree on: same-type back-to-back signals
# are coalesced by the kernel (measured: one INT+INT pair in five produced no
# second handler at all), and near-simultaneous DIFFERENT signals race between
# send order and Linux's lowest-signal-number-first delivery (measured:
# TERM→INT yielded rc 143 once), while HUP(1)→INT(2) is first under BOTH
# rules, so INT is deterministically the second and last handler.
command kill -HUP "$disp" 2>/dev/null
command kill -INT "$disp" 2>/dev/null
end_bg
elapsed=$(( $(date +%s) - t0 ))
dlog="$state/logs/dispatcher.log"
[[ $rc -eq 130 ]] ||
    fail "escalated run exited rc=$rc, want 130 (the second signal's status)" \
        "$(cat "$state/run.out")"
grep -qF 'is the SECOND signal — immediate SIGKILL sweep' "$dlog" ||
    fail "dispatcher.log lacks the SECOND-signal line:" "$(cat "$dlog" 2>/dev/null)"
grep -qF 'SIGKILL immediately (second signal)' "$dlog" ||
    fail "dispatcher.log lacks the immediate-sweep line:" "$(cat "$dlog" 2>/dev/null)"
[[ $elapsed -le 10 ]] ||
    fail "escalated run took ${elapsed}s after the second signal — it waited out the 30 s grace" \
        "$(cat "$dlog" 2>/dev/null)"
grep -q 'Build interrupted' "$state/run.out" ||
    fail "no 'Build interrupted' after the escalation" "$(cat "$state/run.out")"
rr_rc=$(rr_scalar rc <"$state/run.out") ||
    fail "no run record after the escalation" "$(cat "$state/run.out")"
[[ $rr_rc == 130 ]] ||
    fail "escalated run-record rc: $rr_rc, want 130"
sleep 0.3
if ps -eo args= | grep -F 'build-all.fish --lane-job' | grep -F "$fixture" |
    grep -v grep >/dev/null; then
    fail "a lane survived the second-signal sweep:" \
        "$(ps -eo pid=,args= | grep -F 'build-all.fish --lane-job' | grep -F "$fixture" |
        grep -v grep)"
fi
if ps -eo args= | grep -F "$fixture/bin/makepkg" | grep -v grep >/dev/null; then
    fail "a stub makepkg survived the second-signal sweep"
fi

# ── 14. run-scoped result files: a foreign line never kills the lane ───────
echo "phase 14: foreign result identity is ignored (R-F9)"
state="$fixture/state-foreign"
mk_env "$state" 3
RUN_ENV+=("_GSA_RUN_ID=runone")
run_bg "$state/run.out" fish "$fixture/build-all.fish" "${BARGS[@]}"
wait_for_file "$state/built/p1" 15 ||
    fail "foreign-probe run never started building" "$(cat "$state/run.out")"
rf="$state/logs/.lane.runone.1.result"
printf 'pX 0 1\n' >"$rf" ||
    fail "could not plant the foreign result line in $rf"
end_bg
[[ $rc -eq 0 ]] ||
    fail "run with a foreign result line failed: rc=$rc" "$(cat "$state/run.out")"
row=$(rr_row p1 <"$state/run.out") ||
    fail "no run-record row for p1" "$(cat "$state/run.out")"
[[ $row =~ ^p1\ succeeded\ [0-9]+\ [0-9]+\ ok$ ]] ||
    fail "run-record row for p1 is '$row', want 'p1 succeeded <n> <n> ok'"
if grep -q 'lane lost' "$state/run.out"; then
    fail "a foreign line misclassified the healthy lane:" "$(cat "$state/run.out")"
fi
if grep -q 'no valid result' "$state/run.out"; then
    fail "a foreign line was treated as a missing result:" "$(cat "$state/run.out")"
fi
if grep -q 'reap anomaly' "$state/logs/dispatcher.log" 2>/dev/null; then
    fail "dispatcher.log records a reap anomaly for a foreign line:" \
        "$(cat "$state/logs/dispatcher.log")"
fi

# ── 15. result-clear refusal (R-F33) ──────────────────────────────────────
echo "phase 15: result-clear refusal"
state="$fixture/state-clear"
mk_env "$state" 0.5
RUN_ENV+=("_GSA_RUN_ID=runone")
mkdir -p "$state/logs/.lane.runone.1.result"
printf 'not empty\n' >"$state/logs/.lane.runone.1.result/junk"
run_bg "$state/run.out" fish "$fixture/build-all.fish" "${BARGS[@]}"
end_bg
[[ $rc -ne 0 ]] ||
    fail "run with an unremovable result slot reported success" \
        "$(cat "$state/run.out")"
grep -qF 'cannot clear a stale lane result — refusing to dispatch p1' "$state/run.out" ||
    fail "missing result-clear refusal message:" "$(cat "$state/run.out")"
row=$(rr_row p1 <"$state/run.out") ||
    fail "no run-record row for p1" "$(cat "$state/run.out")"
[[ $row == 'p1 failed 1 0 result-clear-failed' ]] ||
    fail "run-record row is '$row', want 'p1 failed 1 0 result-clear-failed'"
[[ -d $state/logs/.lane.runone.1.result ]] ||
    fail "the unremovable result slot disappeared — the gate must refuse, not force"

# ── 16. lane payload gates + `-j` pair normalisation ───────────────────────
echo "phase 16: lane payload gates (control chars, bad identity, -j pairs)"
state="$fixture/state-payload"
mk_env "$state" 0
mkdir -p "$state/logs"

# (a) a control character in the result path is refused BEFORE any work:
#     rc 2 (invocation error, never a lane outcome), no result file, and the
#     lane body never ran (no marker, no pacman shim).
res_ctrl="$state/logs/.lane-ctrl"$'\x01'".result"
rc=0
env "${RUN_ENV[@]}" fish "$fixture/build-all.fish" \
    --lane-job p1 "$res_ctrl" 1 0 0 0 1 0 >"$state/ctrl.out" 2>&1 || rc=$?
[[ $rc -eq 2 ]] ||
    fail "control-char result path rc=$rc, want 2 (invocation error)" \
        "$(cat "$state/ctrl.out")"
grep -qF 'Error: --lane-job received a result path with control characters' \
    "$state/ctrl.out" ||
    fail "missing control-character refusal:" "$(cat "$state/ctrl.out")"
[[ ! -e $res_ctrl ]] ||
    fail "a refused invocation still wrote a result file"
[[ ! -e $state/built/p1 ]] ||
    fail "the control-char refusal ran work before refusing"
[[ ! -e $state/logs/.pacman-shim ]] ||
    fail "the control-char refusal reached the lane body"

# (b) a pkg id outside the codec charset can never reach the result wire:
#     the lane exits 125 (lane_outcome_lost) and writes NO result file.
res_bad="$state/logs/.lane-badid.result"
rc=0
env "${RUN_ENV[@]}" fish "$fixture/build-all.fish" \
    --lane-job "bad id" "$res_bad" 1 0 0 0 1 0 >"$state/badid.out" 2>&1 || rc=$?
[[ $rc -eq 125 ]] ||
    fail "bad-identity lane rc=$rc, want 125 (lane_outcome_lost)" \
        "$(cat "$state/badid.out")"
grep -qF 'lane result write failed' "$state/badid.out" ||
    fail "bad-identity lane did not fail loudly:" "$(cat "$state/badid.out")"
[[ ! -e $res_bad ]] ||
    fail "a bad-identity lane published a result file"

# (c) MAKEFLAGS/NINJAFLAGS `-j N` pairs re-export as the lane's -j1 with no
#     stranded operand token (the invocation passes job count 1).
res_flags="$state/logs/.lane-flags.result"
flags_log="$state/flags.log"
rc=0
env "${RUN_ENV[@]}" MAKEFLAGS='-j 4 --no-print-directory' NINJAFLAGS='-j 8' \
    GSA_FAKE_FLAGS_LOG="$flags_log" \
    fish "$fixture/build-all.fish" --lane-job p1 "$res_flags" 1 0 0 0 1 0 \
    >"$state/flags.out" 2>&1 || rc=$?
[[ $rc -eq 0 ]] ||
    fail "flags-probe lane rc=$rc, want 0" "$(cat "$state/flags.out")"
[[ -s $flags_log ]] ||
    fail "stub makepkg never observed its flags" "$(cat "$state/flags.out")"
mf_line=$(grep '^MAKEFLAGS=' "$flags_log" | tail -1)
nf_line=$(grep '^NINJAFLAGS=' "$flags_log" | tail -1)
[[ $mf_line == *'-j1'* ]] ||
    fail "MAKEFLAGS lacks the lane's -j1: '$mf_line'"
[[ $mf_line == *'--no-print-directory'* ]] ||
    fail "MAKEFLAGS lost --no-print-directory: '$mf_line'"
for tok in ${mf_line#MAKEFLAGS=}; do
    [[ $tok == 4 ]] &&
        fail "MAKEFLAGS kept the stranded -j operand as a bare token: '$mf_line'"
done
[[ $nf_line == *'-j1'* ]] ||
    fail "NINJAFLAGS lacks the lane's -j1: '$nf_line'"
for tok in ${nf_line#NINJAFLAGS=}; do
    [[ $tok == 8 ]] &&
        fail "NINJAFLAGS kept the stranded -j operand as a bare token: '$nf_line'"
done

if ps -eo args= | grep -F "$fixture" | grep -v grep >/dev/null; then
    fail "a fixture process survived:" \
        "$(ps -eo args= | grep -F "$fixture" | grep -v grep)"
fi

# ── 17. SIGINT during pre-dispatch: abort before dispatch (R-F27 latch) ────
# WHY: the interrupt latch used to be consumed only inside run_lanes'
# dispatch loop, so a ^C during the pre-dispatch phase (the ABI gates, the
# plan) was IGNORED and the run went on to dispatch work the operator had
# just cancelled. abort_before_dispatch now honours the latch at every
# gate-loop boundary and immediately before run_lanes. The trigger is
# deterministic, never a sleep-and-hope ^C race: the stub pacman's
# `pacman -Q rust-git` probe — the layer-1 abi=must batch gate asking
# whether the omitted member is installed (abi-batch-policy.sh B's exact
# topology) — sends exactly ONE SIGINT to the builder and logs the pid it
# targeted, so delivery, handler and latch are one provable chain. The
# signal must win OVER the gate's own decision (the installed member would
# otherwise refuse the selection) and over dispatch entirely.
(
    echo "phase 17: SIGINT during the pre-dispatch ABI gate aborts before dispatch"
    state="$fixture/state-predispatch-int"
    mk_env "$state" 0
    mklog="$state/makepkg.log"
    tlog="$state/int-trigger.log"
    RUN_ENV+=(
        "GSA_FAKE_MAKEPKG_LOG=$mklog"
        "GSA_FAKE_PACMAN_LOG=$state/pacman.log"
        "GSA_FAKE_INSTALLED=rust-git"
        "GSA_FAKE_INT_QUERY=rust-git"
        "GSA_FAKE_INT_TRIGGER_DIR=$state/int-triggered"
        "GSA_FAKE_INT_TRIGGER_LOG=$tlog"
    )
    run_bg "$state/run.out" fish "$fixture/build-all.fish" \
        --allow-broken-rustc --no-deps --no-sync --lanes 1 --jobs 1 llvm-git p1
    end_bg

    # The signal's own status via gsa_signal_exit_rc — never a flat failure.
    [[ $rc -eq 130 ]] ||
        fail "pre-dispatch SIGINT run exited rc=$rc, want 130 (the signal's own status)" \
            "$(cat "$state/run.out")"
    grep -q 'Build interrupted' "$state/run.out" ||
        fail "no 'Build interrupted' warning on the pre-dispatch abort:" \
            "$(cat "$state/run.out")"

    # The machine-checkable run record is rendered on this abort path too.
    rr_outcome=$(rr_scalar outcome <"$state/run.out") ||
        fail "no run record on the pre-dispatch abort" "$(cat "$state/run.out")"
    [[ $rr_outcome == interrupted ]] ||
        fail "run-record outcome is '$rr_outcome', want 'interrupted'"
    rr_rc=$(rr_scalar rc <"$state/run.out") ||
        fail "no run-record rc: scalar" "$(cat "$state/run.out")"
    [[ $rr_rc == 130 ]] ||
        fail "run-record rc: is '$rr_rc', want 130 (the signal's own status)"

    # Every selected package is honestly never-started: nothing dispatched.
    for pkg in llvm-git p1; do
        row=$(rr_row "$pkg" <"$state/run.out") ||
            fail "no run-record row for $pkg" "$(cat "$state/run.out")"
        [[ $row == "$pkg never-started - - interrupted-before-start" ]] ||
            fail "run-record row for $pkg is '$row', want '$pkg never-started - - interrupted-before-start'"
    done
    [[ $(rr_rows <"$state/run.out" | wc -l) -eq 2 ]] ||
        fail "run record has unexpected extra rows:" "$(rr_rows <"$state/run.out")"

    # NO build was dispatched — the stub makepkg log stays empty.
    [[ ! -s $mklog ]] ||
        fail "stub makepkg ran despite the pre-dispatch abort:" "$(cat "$mklog")"
    [[ ! -e $state/built ]] ||
        fail "a build marker landed despite the pre-dispatch abort:" \
            "$(ls -la "$state/built" 2>/dev/null)"

    dlog="$state/logs/dispatcher.log"
    [[ -f $dlog ]] ||
        fail "dispatcher.log was never created"
    # The latch fired (the handler named the signal) AND the abort happened
    # before dispatch (the marker line only abort_before_dispatch prints).
    grep -qF 'signal: INT received' "$dlog" ||
        fail "dispatcher.log does not record the INT delivery:" "$(cat "$dlog")"
    grep -qF 'Build interrupted (last signal: INT, before dispatch)' "$dlog" ||
        fail "dispatcher.log lacks the abort-before-dispatch marker:" "$(cat "$dlog")"

    # Exactly ONE SIGINT left this stub (a second would escalate to the
    # SIGKILL sweep — the run must have seen a first signal only).
    [[ -f $tlog && $(wc -l <"$tlog") -eq 1 ]] ||
        fail "the INT trigger must fire exactly once, saw:" "$(cat "$tlog" 2>/dev/null)"
    if grep -q 'SECOND signal' "$dlog"; then
        fail "a single trigger produced a second-signal escalation:" "$(cat "$dlog")"
    fi

    # PID-targeting proof: the pid the stub signalled is the pid whose handler
    # latched the interrupt — delivery, handler and latch are one chain.
    tgt=$(sed -n 's/.* target=\([0-9][0-9]*\)$/\1/p' "$tlog" | head -1)
    hpid=$(sed -n 's/.*signal: INT received (pid=\([0-9][0-9]*\),.*/\1/p' "$dlog" | head -1)
    [[ -n $tgt && $tgt == "$hpid" ]] ||
        fail "the stub's SIGINT target ($tgt) is not the pid whose handler latched it ($hpid)" \
            "trigger: $(cat "$tlog")" "dispatcher: $(cat "$dlog")"
) || exit 1

printf 'signal-abort-lock fixture: PASS\n'
