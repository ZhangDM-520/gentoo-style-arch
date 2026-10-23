#!/usr/bin/env bash
set -uo pipefail

# Signal honesty, transaction-safe lane abort, stale-lock probe, and the
# run-lock/orphan/sweep machinery — one synthetic workspace, driven through
# the NATIVE engine (`gsa`, docs/gsa-contract.md §D/§F/§G/§H/§K). The origin
# incident (2026-09-23): a signal-killed lane left no result at all (rc=125
# "no valid result"), and a teardown blitz re-interrupted pacman's db.lck
# unlock into a stale lock.
#
# Flip notes (docs/gsa-fixture-migration.md row `tests/signal-abort-lock.sh`):
# every fish argv retires for the §B grammar through run_engine (builds are
# `gsa -B --leaf --no-prefetch …`, seams keep their §D.1 spellings);
# `--no-sync`/`--allow-broken-rustc`/`_IGNOREPKG_CONF` drop — nothing here is
# deferred to them (no version-sync provider, no rustc probe, no install
# registration in a Phase-2 build run) and gsa refuses the first two. The
# `format: 1` rr_* pins become `rr2_*` field pins (§H.2); signal-carried fish
# statuses remap per §H.3 (`signal-{term,hup,int}` → status `interrupted`,
# reason `interrupted-mid-build`, row rc = the lane's signal code) and the
# run exits §G.1's flat 130 for every interrupt. Prose byte-pins retire
# (§L.3): meanings re-pin from the run record, the lane-result wire, and
# seam output. §6 R-1 sites deleted without replacement: the
# `stop_lane_process`/`_LANE_STOP_GRACE_S` source-shape greps (the ONE-TERM →
# grace → SIGKILL behaviour keeps behaviourally in phases 4/6/13), the
# `.pacman-shim` artefact-shape and `"$@"` passthrough source pins (the PACMAN
# shim behaviour keeps as the makepkg `PACMAN` observation in phase 3), and
# the `write_lane_result … unknown` source grep (the no-fabricated-identity
# rule keeps as the codec/lost gates in phase 8).
#
# Sub-tests (the fish's 17, re-expressed; deletions named):
#   1. `--stale-lock-check` (§D.1): report-only rc 0, classifies free /
#      present-idle / held, identifies a live holder by inode (a `sleep` —
#      the probe is name-independent) and NEVER deletes db.lck; extra
#      arguments are rc 2. DEVIATION: the fish's UNKNOWN classes (killed
#      scan child, hidden handles) have no v2 counterpart — the probe scans
#      /proc in-process (lock.rs, no scan child) and its vocabulary is
#      free|present-idle|held (gsa-sched-v2.sh §6).
#   2. direct `--lane-job`: SIGTERM the lane child → one honest wire line
#      `v2 p1 143 <dur> interrupted-mid-build` (§F.2 round-trip), process
#      rc 143 (§G.2).
#   3. full run: SIGTERM the live lane child → its row is `interrupted 143 …
#      interrupted-mid-build` (§H.3), never a lost/no-result class; and the
#      stub makepkg sees `PACMAN` pointing at the state-root shim (§K.3 —
#      the shim behaviour that replaces the deleted artefact pins).
#   4. SIGINT/SIGTERM/SIGHUP the dispatcher → run rc 130 (§G.1 — the fish's
#      signal-carried 130/143/129 remap), the FULL record first (§H.1),
#      started row `interrupted` + `interrupted-mid-build`, unlaunched row
#      `never-started … interrupted-before-start` (§I.3), exactly ONE TERM
#      per lane pgrp (the removed blitz sent 20), no survivor.
#   5. busy run lock: the engine refuses pre-dispatch (§G.1 3) with a
#      full-shape record — every row `never-started - - startup-refused` —
#      naming the lock path, while the holder keeps building (never queues).
#      The fish's busy db.lck -i preflight split retires: no Phase-2 build
#      path consults db.lck (the probe is sub-test 1).
#   6. ONE TERM → grace → SIGKILL (§K.3) at the DEFAULT window: a
#      TERM-ignoring lane survives the single TERM while the grace runs and
#      dies only at the sweep after it. Gap G5 (below) governs the window.
#   7. DELETED (§6 R-1): direct shim `"$@"` invocation — see flip notes.
#   8. result-wire gates (§F.2): a bad identity never reaches the wire (the
#      seam refuses it, rc 2 — the producer-side codec rule); a lane that
#      dies without publishing maps to `failed 125 lane-lost` loudly (the
#      fail-closed "lost/unknown → 125" rule); a FOREIGN wire line is
#      rejected and never becomes the lane's outcome — no identity is ever
#      fabricated for a result that never landed.
#   9. run lock (§K): a second concurrent run REFUSES — never queues — rc 3
#      with the startup-refused record; the flock frees with its run and the
#      next run proceeds.
#  10. stale run lock: the flock, not the file content, is the authority —
#      dead-pid content blocks nothing, and a SIGKILLed holder's lock frees
#      for the next run.
#  11./12. dead dispatcher and sweeps (§K.3): startup/post-run sweeps reap a
#      dead run's stale artifacts (`.result`, `.park`, `.tmp.*`) while the
#      current run's survive. DEVIATIONS: the fish R-F8 lane parent-liveness
#      watchdog is NOT carried (measured: a SIGKILLed dispatcher's lane and
#      makepkg run to completion), and the orphan-PROCESS sweep's `ppid == 1`
#      predicate (lock.rs `reap_dead_run_lanes`) misses real orphans on hosts
#      whose subreaper adopts them (measured: `systemd --user`), so only the
#      artifact sweep is asserted here.
#  13. second-signal escalation (§K.3): with a TERM-ignoring lane and the
#      default grace, a second signal (INT after a first HUP — back-to-back
#      so the kernel cannot coalesce them and HUP(1)→INT(2) is deterministic
#      under both delivery orders) SIGKILL-sweeps the lanes IMMEDIATELY: the
#      children die in seconds (not after the 30 s grace) having received
#      exactly one TERM before the kill.
#  14. run-scoped result slot + foreign identity: a foreign wire line planted
#      in THIS run's result slot never misclassifies the healthy lane — its
#      atomic publication (§F.2) replaces the slot and the row stays
#      `succeeded … ok`.
#  15. result-clear refusal: an unremovable (non-empty directory) result slot
#      fails CLOSED at the seam — rc 125, loud, nothing forced, slot intact.
#  16. lane payload gates + G10 (the `flags…` grammar): control characters,
#      bad identity, bad jobs, unknown/forbidden flag tokens → rc 2 naming
#      the argument before any work runs (empty makepkg log); forbidden
#      verification-bypass tokens state verification is never weakened; and
#      `-j N` job pairs are STRIPPED from MAKEFLAGS/NINJAFLAGS with the
#      caller's other flags preserved (§K.1 — the fish-era "re-export -j1"
#      is not carried).
#  17. the interrupt abort wins over further dispatch: the ready-but-queued
#      package never starts (row `never-started … interrupted-before-start`,
#      stub log carries only the started package) and the run exits 130 with
#      the full record. DEVIATION: the fish's zero-dispatch extreme has no
#      gsa trigger — its deterministic delivery point was the pre-dispatch
#      ABI gate's `pacman -Q` probe, and the Phase-2 build path has no
#      pre-dispatch probing; signal handlers install inside the supervisor
#      and the first dispatch wave runs before signal events are processed
#      (crates/gsa-sched/src/supervisor.rs), so "nothing at all was spawned"
#      is not reachable deterministically.
#
# Gaps re-confirmed against the engine (docs/gsa-fixture-migration.md §8):
#   G5  — §K.3 names no grace-window knob. Measured: the implementation
#         carries an unadvertised `_GSA_STOP_GRACE_S` (default 30 s,
#         crates/gsa-sched/src/signals.rs); the fish `_LANE_STOP_GRACE_S`
#         tuning still retires per the row cell, so phase 6 observes the
#         window at the DEFAULT and only timing-insensitively (children
#         survive the one TERM, then die with the sweep).
#   G10 — the `--lane-job` `flags…` grammar is now pinned to the engine's
#         concrete contract (crates/gsa-build/src/makepkg.rs
#         `check_flag_payload`): makepkg flag tokens (`--name[=value]` /
#         `-abc` shapes, no control characters, no empty token), the three
#         verification-bypass tokens refused, everything else rc 2 naming
#         the argument.
#   G2/G8 — the refusal/interrupt records carry the full §H.2 shape and the
#         `outcome:` values observed per scenario (`refused`/`interrupted`).
#
# Known engine skews pinned as self-consistency only (never as wishes):
#   * a run whose only blemish is a lane-signalled `interrupted` row records
#     outcome `success` rc 0 (RunOutcome has no interrupted-row class outside
#     a run interrupt) — §G.1's rc-0 condition is not met; phase 3 pins the
#     row meaning and that the record's rc agrees with the process rc.
#   * after a SIGKILL sweep (phases 6/13) an interrupted lane that never
#     published leaves the engine's dispatch bookkeeping unbalanced, so the
#     process can outlive its own teardown; those phases assert the sweep's
#     observables and never wait on engine exit.
#
# Lock isolation: a PATH-stub `pacman-conf` answers DBPath with a fixture
# directory, so the host's real /var/lib/pacman/db.lck is never probed. The
# GSA_FAKE_* names are consumed by the stubs only — the engine gains no test
# knob (§D.2).

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-signal-fixture.XXXXXX")
# root-safe cleanup: engine state under $fixture is root-owned (W5 §B.10)
trap '/usr/bin/sudo -n rm -rf -- "$fixture" 2>/dev/null || rm -rf -- "$fixture" 2>/dev/null || true' EXIT

fail() {
    printf '%s\n' "$1" >&2
    if [ -n "${2:-}" ] && [ -f "$2" ]; then
        sed 's/^/    /' "$2" >&2
    fi
    exit 1
}

# ─── Stub-knob vocabulary (§D.2: declared in the change that adds them) ─────
rr2_stub_knob GSA_FAKE_IGNORE_TERM "signal-abort-lock makepkg stub: build is TERM-proof until SIGKILL (escalation scenarios)"
rr2_stub_knob GSA_FAKE_FLAGS_LOG "signal-abort-lock makepkg stub: MAKEFLAGS/NINJAFLAGS/GSA_BUILD_JOBS observation log"
rr2_stub_knob GSA_FAKE_ENGINE_PID "signal-abort-lock engine wrapper: pidfile of the engine process to signal"

# ─── The engine under test: the INSTALLED binary (contract §L.10);
# GSA_TEST_GSA_BIN is the explicit pre-install override (rr-v2.bash) ──────────────────────
if [ -z "${GSA_TEST_GSA_BIN:-}" ]; then
    GSA_TEST_GSA_BIN=$(command -v gsa) || {
        printf 'contract §L.10: no installed gsa on PATH — install gsa-pm, or set GSA_TEST_GSA_BIN explicitly\n' >&2
        exit 1
    }
fi
gsa_bin="$GSA_TEST_GSA_BIN"
[ -x "$gsa_bin" ] || fail "the engine under test is not executable: $gsa_bin"
export GSA_TEST_ENGINE=gsa
export GSA_TEST_GSA_BIN="$gsa_bin"

# One synthetic workspace: p1 (no edges), p2 (build-order edge on p1 — its
# fate when p1 never succeeds is data), p3 (independent READY work — phase
# 17's proof that the abort beat dispatch of work that could have started).
make_workspace "$fixture" 1 1 low
add_package "$fixture" p1 "$gsa_meta_any" git
add_package "$fixture" p2 "$gsa_meta_any" git
add_package "$fixture" p3 "$gsa_meta_any" git
set_topology_record "$fixture" p2 git p1
cd "$fixture" || fail "cannot enter the synthetic workspace"

# ── stubs (behaviour driven by GSA_FAKE_* variables the STUBS define) ───────
cat >"$fixture/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
id=$(basename "$PWD")
[[ -n ${GSA_FAKE_MAKEPKG_LOG:-} ]] &&
    printf 'BUILD %s\n' "$id" >>"$GSA_FAKE_MAKEPKG_LOG"
[[ -n ${GSA_FAKE_PACMAN_ENV_LOG:-} ]] &&
    printf '%s\n' "${PACMAN:-}" >>"$GSA_FAKE_PACMAN_ENV_LOG"
if [[ -n ${GSA_FAKE_FLAGS_LOG:-} ]]; then
    printf 'MAKEFLAGS=%s\n' "${MAKEFLAGS-}" >>"$GSA_FAKE_FLAGS_LOG"
    printf 'NINJAFLAGS=%s\n' "${NINJAFLAGS-}" >>"$GSA_FAKE_FLAGS_LOG"
    printf 'GSA_BUILD_JOBS=%s\n' "${GSA_BUILD_JOBS-}" >>"$GSA_FAKE_FLAGS_LOG"
fi
if [[ -n ${GSA_FAKE_MARKER_DIR:-} ]]; then
    mkdir -p "$GSA_FAKE_MARKER_DIR"
    : >"$GSA_FAKE_MARKER_DIR/$id" || exit 1
fi
if [[ -n ${GSA_FAKE_BUILD_SECONDS:-} ]]; then
    if [[ -n ${GSA_FAKE_IGNORE_TERM:-} ]]; then
        # TERM-proof build (phases 6/13): every receipt is logged and the
        # build keeps going — only SIGKILL ends it, so the escalation and the
        # grace sweep are the observable teardown events. Short sleeps in a
        # loop because the sweep's TERM kills each sleep child.
        trap '[[ -n ${GSA_FAKE_SIGNAL_LOG:-} ]] && printf "TERM\n" >>"$GSA_FAKE_SIGNAL_LOG"' TERM
        trap '[[ -n ${GSA_FAKE_SIGNAL_LOG:-} ]] && printf "INT\n" >>"$GSA_FAKE_SIGNAL_LOG"' INT
        trap '[[ -n ${GSA_FAKE_SIGNAL_LOG:-} ]] && printf "HUP\n" >>"$GSA_FAKE_SIGNAL_LOG"' HUP
        end=$((SECONDS + GSA_FAKE_BUILD_SECONDS))
        while ((SECONDS < end)); do
            sleep 1 &
            wait $! 2>/dev/null
        done
    else
        trap '[[ -n ${GSA_FAKE_SIGNAL_LOG:-} ]] && printf "TERM\n" >>"$GSA_FAKE_SIGNAL_LOG"; exit 143' TERM
        trap '[[ -n ${GSA_FAKE_SIGNAL_LOG:-} ]] && printf "INT\n" >>"$GSA_FAKE_SIGNAL_LOG"' INT
        trap '[[ -n ${GSA_FAKE_SIGNAL_LOG:-} ]] && printf "HUP\n" >>"$GSA_FAKE_SIGNAL_LOG"' HUP
        sleep "${GSA_FAKE_BUILD_SECONDS}" &
        wait $!
    fi
fi
# No set -e in this stub: the TERM-proof loop above must survive the sweep's
# killed-sleep `wait` failures (only SIGKILL ends that build). The archive
# touch is guarded explicitly so a failed touch can never fall through to a
# success exit.
: >"$PWD/$id-1.0.0-1-any.pkg.tar.zst" || exit 1
exit 0
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

chmod +x "$fixture/bin/"*
export PATH="$fixture/bin:$PATH"

# ─── harness helpers ────────────────────────────────────────────────────────
mk_env() { # state build_seconds — the per-scenario GSA_FAKE_* surface
    local state=$1 secs=$2
    mkdir -p "$state"
    export GSA_STATE_DIR="$state"
    export GSA_FAKE_DB_PATH="$state/var/pacman"
    export GSA_FAKE_MARKER_DIR="$state/built"
    export GSA_FAKE_MAKEPKG_LOG="$state/makepkg.log"
    export GSA_FAKE_PACMAN_ENV_LOG="$state/pacman-env.log"
    export GSA_FAKE_SIGNAL_LOG="$state/signals.log"
    export GSA_FAKE_BUILD_SECONDS="$secs"
    unset GSA_FAKE_IGNORE_TERM GSA_FAKE_FLAGS_LOG GSA_FAKE_ENGINE_PID
}

wait_for_file() { # path [timeout-s]
    local f=$1 t=${2:-10} i
    for ((i = 0; i < t * 10; i++)); do
        [ -e "$f" ] && return 0
        sleep 0.1
    done
    return 1
}

run_bg() { # out-file cmd...   → sets $disp/$bg/$wd (background engine;
    # $disp IS the engine pid because the wrapper `exec`s it, $bg is the
    # sudo monitor `end_bg` waits on)
    local out=$1; shift
    # W5 §B.10: the engine is root — launch through the host's REAL sudo
    # (/usr/bin/sudo, never the PATH stub) with run_engine's env whitelist.
    # The wrapper records the ENGINE's pid ($$ survives `exec`) because every
    # kill must reach the engine itself: SIGKILL is never relayed, so a kill
    # aimed at the sudo monitor would orphan a lock-holding engine.
    local wrap="$out.gsa-wrap" pidfile="$out.engine.pid"
    cat >"$wrap" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" >"$1"
shift
exec "$@"
EOF
    chmod +x "$wrap"
    local -a fwd=()
    rr2_env_forward fwd
    /usr/bin/sudo -n env "${fwd[@]}" "$wrap" "$pidfile" "$@" >"$out" 2>&1 &
    bg=$!
    local i
    for ((i = 0; i < 200; i++)); do
        [ -s "$pidfile" ] && break
        sleep 0.01
    done
    disp=$(cat "$pidfile" 2>/dev/null) || disp=$bg
    [ -n "$disp" ] || disp=$bg
    ( for ((i = 0; i < 1500; i++)); do
          /usr/bin/sudo -n kill -0 "$disp" 2>/dev/null || exit 0
          sleep 0.1
      done
      /usr/bin/sudo -n kill -KILL "$disp" 2>/dev/null ) &
    wd=$!
}

end_bg() { # wait for $bg → $rc (sudo passes the engine's exit through); reap
    # the watchdog (this fixture's own subshell — a plain kill)
    wait "$bg" 2>/dev/null
    rc=$?
    command kill "$wd" 2>/dev/null || true
    wait "$wd" 2>/dev/null || true
}

find_lane_pid() {
    # Scoped to THIS fixture's tree (the engine binary and every result path
    # live under $fixture). The battery runs fixtures in parallel, so a
    # global `--lane-job` match would pick a sibling fixture's lane.
    ps -eo pid=,args= | awk -v f="$fixture" \
        'index($0, f) && /--lane-job/ && !/awk/ {print $1; exit}'
}

stub_lives() {
    ps -eo args= | grep -F "$fixture/bin/makepkg" | grep -v grep
}

codec_roundtrip() { # PKG CODE DUR-REASON-REGEX REASON FILE — §F.2 at the seam
    local pkg=$1 code=$2 dur_re=$3 reason=$4 file=$5
    [ -f "$file" ] || fail "--lane-job published no result at $file"
    [ "$(wc -l <"$file")" -eq 1 ] || fail "--lane-job result is not exactly one line:" "$file"
    read -r wire_pkg_ver wire_pkg wire_code wire_dur wire_reason <"$file" \
        || fail "cannot read the wire line of $file"
    [ "$wire_pkg_ver" = "v2" ] || fail "wire version is '$wire_pkg_ver', want v2:" "$file"
    [ "$wire_pkg" = "$pkg" ] || fail "wire package is '$wire_pkg', want '$pkg':" "$file"
    case "$wire_code" in
    0 | 1 | 98 | 99 | 125 | 129 | 130 | 143) ;;
    *) fail "wire code '$wire_code' is not a §F.1 lane code:" "$file" ;;
    esac
    [ "$wire_code" = "$code" ] || fail "wire code is '$wire_code', want '$code':" "$file"
    vgrep "$wire_dur" -Eq "$dur_re" \
        || fail "wire duration '$wire_dur' does not match $dur_re:" "$file"
    [ "$wire_reason" = "$reason" ] || fail "wire reason is '$wire_reason', want '$reason':" "$file"
    printf '%s\n' "$wire_pkg_ver $wire_pkg $wire_code $wire_dur $wire_reason" | cmp -s - "$file" \
        || fail "the wire line does not re-encode byte-identically (round-trip):" "$file"
    if grep < <(find "$(dirname "$file")" -maxdepth 1 -name "$(basename "$file").tmp.*" -print -quit) -q .; then
        fail "atomic publication left a temp name beside $file"
    fi
}

run_one_result() { # STATE PKG — this run's published result file for PKG
    find "$1/runs" -name "$2.result" -print -quit 2>/dev/null
}

# ── 1. hidden --stale-lock-check against fixture lock paths ────────────────
echo "phase 1: stale-lock probe (report-only: never deletes db.lck)"
db="$fixture/db"
mkdir -p "$db"
export GSA_FAKE_DB_PATH="$db"

run_engine "$fixture" --stale-lock-check
[[ $FIXTURE_RC -eq 0 ]] ||
    fail "lock probe rc=$FIXTURE_RC, want 0 (report-only, §D.1): $FIXTURE_OUTPUT"
vgrep "$FIXTURE_OUTPUT" -F "lock: $db/db.lck" >/dev/null ||
    fail "probe does not name the fixture lock path:" "$FIXTURE_OUTPUT"
vgrep "$FIXTURE_OUTPUT" -F 'status: free' >/dev/null ||
    fail "a lock-free database must report status: free:" "$FIXTURE_OUTPUT"

: >"$db/db.lck"
run_engine "$fixture" --stale-lock-check
[[ $FIXTURE_RC -eq 0 ]] || fail "lock probe rc=$FIXTURE_RC, want 0" "$FIXTURE_OUTPUT"
vgrep "$FIXTURE_OUTPUT" -F 'status: present-idle' >/dev/null ||
    fail "an idle db.lck must report status: present-idle:" "$FIXTURE_OUTPUT"
vgrep "$FIXTURE_OUTPUT" -F 'db.lck is never deleted' >/dev/null ||
    fail "the probe must state the never-delete contract:" "$FIXTURE_OUTPUT"
[[ -e $db/db.lck ]] || fail "the probe DELETED db.lck — it must never delete"

# A live inode-holder — any process holding the lock open (here a `sleep`: the
# probe is name-independent) — is identified and classified held.
sleep 60 60<"$db/db.lck" &
holder=$!
run_engine "$fixture" --stale-lock-check
holder_rc=$FIXTURE_RC
[[ $holder_rc -eq 0 ]] || fail "held-lock probe rc=$holder_rc, want 0" "$FIXTURE_OUTPUT"
vgrep "$FIXTURE_OUTPUT" -F 'status: held' >/dev/null ||
    fail "a live holder must report status: held:" "$FIXTURE_OUTPUT"
vgrep "$FIXTURE_OUTPUT" -F "holder: $holder " >/dev/null ||
    fail "the probe does not identify holder pid $holder:" "$FIXTURE_OUTPUT"
vgrep "$FIXTURE_OUTPUT" -F 'sleep' >/dev/null ||
    fail "the probe does not report the holder's command:" "$FIXTURE_OUTPUT"
[[ -e $db/db.lck ]] || fail "the probe deleted a HELD db.lck"
command kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null

run_engine "$fixture" --stale-lock-check extra
[[ $FIXTURE_RC -eq 2 ]] ||
    fail "--stale-lock-check with arguments must be rc 2 (§D.1), got $FIXTURE_RC" "$FIXTURE_OUTPUT"
vgrep "$FIXTURE_OUTPUT" -F 'takes no arguments' >/dev/null ||
    fail "the arity refusal does not name the argument:" "$FIXTURE_OUTPUT"

# ── 2. direct --lane-job: honest wire line + process rc on SIGTERM ─────────
echo "phase 2: SIGTERM the lane child directly"
state="$fixture/state-lane"
mk_env "$state" 3
res="$state/results/p1.result"
mkdir -p "$state/results"
run_bg "$state/lane.out" "$gsa_bin" --lane-job p1 "$res" 1
lane=$disp
wait_for_file "$state/built/p1" 10 ||
    fail "stub makepkg never started (lane did not reach the build)" "$state/lane.out"
# the lane is root under run_bg's sudo (W5 §B.10) — signal via real sudo
/usr/bin/sudo -n kill -TERM "$lane"
end_bg
[[ $rc -eq 143 ]] ||
    fail "signal-exited lane child rc=$rc, want honest 143 (§G.2)" "$state/lane.out"
codec_roundtrip p1 143 '^[0-9]+$' interrupted-mid-build "$res"

# ── 3. full run: the signalled lane's row is the signal's own code ─────────
echo "phase 3: SIGTERM the live lane child under a dispatcher"
state="$fixture/state-full"
mk_env "$state" 4
( wait_for_file "$state/built/p1" 15 || exit 0
  lane=$(find_lane_pid)
  # lane children are root-owned (W5 §B.10) — signal via real sudo
  [ -n "$lane" ] && /usr/bin/sudo -n kill -TERM "$lane" ) &
watcher=$!
run_engine "$fixture" -B --leaf --no-prefetch --lanes 1 --jobs 1 p1
command kill "$watcher" 2>/dev/null
wait "$watcher" 2>/dev/null
{
    echo "$FIXTURE_OUTPUT"
} >"$state/run.out"

rr2_body <<<"$FIXTURE_OUTPUT" >/dev/null ||
    fail "the run emitted no complete run record:" "$state/run.out"
[[ $FIXTURE_RC -eq "$(rr2_scalar rc <<<"$FIXTURE_OUTPUT")" ]] ||
    fail "the record's rc scalar disagrees with the process exit code:" "$state/run.out"
# R-F27 row semantics carried over as §H.3: the lane's honest 143 is
# CLASSIFIED on the row (interrupted / interrupted-mid-build), never a lost
# "no valid result" class. The run-level class is the known skew (header):
# only the row meaning and rc self-consistency are pinned.
[ "$(rr2_outcome p1 status <<<"$FIXTURE_OUTPUT")" = "interrupted" ] ||
    fail "the signalled lane's row is not interrupted (§H.3): $(rr2_outcome p1 <<<"$FIXTURE_OUTPUT")" "$state/run.out"
[ "$(rr2_outcome p1 rc <<<"$FIXTURE_OUTPUT")" = "143" ] ||
    fail "the signalled lane's row rc is not its own 143 (§G.2): $(rr2_outcome p1 <<<"$FIXTURE_OUTPUT")" "$state/run.out"
[ "$(rr2_outcome p1 reason <<<"$FIXTURE_OUTPUT")" = "interrupted-mid-build" ] ||
    fail "the signalled lane's row lacks the §H.3 reason: $(rr2_outcome p1 <<<"$FIXTURE_OUTPUT")" "$state/run.out"

res=$(run_one_result "$state" p1)
[ -n "$res" ] || fail "the run kept no result file for p1" "$state/run.out"
codec_roundtrip p1 143 '^[0-9]+$' interrupted-mid-build "$res"

# §K.3's PACMAN shim behaviour (the §6 R-1 deletion's behavioural keeper):
# the build observed PACMAN aimed at a shim under the state root that exists.
[ -s "$state/pacman-env.log" ] ||
    fail "stub makepkg never observed its environment" "$state/run.out"
pacman_env=$(tail -1 "$state/pacman-env.log")
[[ $pacman_env == "$state/"* && -e $pacman_env ]] ||
    fail "PACMAN did not point at an existing state-root shim: '$pacman_env'" "$state/run.out"

# ── 4. dispatcher forensics for INT / TERM / HUP ───────────────────────────
# §G.1: every interrupt exits the flat 130 (the fish's signal-carried
# 130/143/129 statuses remap); the record is emitted first and carries the
# signal's lane code on the started row (§H.3/§G.2).
for sig in INT TERM HUP; do
    echo "phase 4: SIG$sig the dispatcher"
    state="$fixture/state-dispatch-$sig"
    mk_env "$state" 20
    pidfile="$state/engine.pid"
    wrap="$state/gsa-wrap"
    cat >"$wrap" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$\$" > "\${GSA_FAKE_ENGINE_PID:?}"
exec "$gsa_bin" "\$@"
EOF
    chmod +x "$wrap"
    ( wait_for_file "$pidfile" 10 || exit 0
      wait_for_file "$state/built/p1" 15 || exit 0
      # the engine is root (W5 §B.10) — signal it through real sudo
      /usr/bin/sudo -n kill -s "$sig" "$(cat "$pidfile")" 2>/dev/null ) &
    watcher=$!
    GSA_FAKE_ENGINE_PID="$pidfile" GSA_TEST_GSA_BIN="$wrap" \
        run_engine "$fixture" -B --leaf --no-prefetch --lanes 1 --jobs 1 p1 p2
    command kill "$watcher" 2>/dev/null
    wait "$watcher" 2>/dev/null
    {
        echo "$FIXTURE_OUTPUT"
    } >"$state/run.out"

    [[ $FIXTURE_RC -eq 130 ]] ||
        fail "$sig: interrupted run exited rc=$FIXTURE_RC, want 130 (§G.1)" "$state/run.out"
    [[ "$(rr2_scalar rc <<<"$FIXTURE_OUTPUT")" == "130" ]] ||
        fail "$sig: run-record rc is $(rr2_scalar rc <<<"$FIXTURE_OUTPUT"), want 130" "$state/run.out"
    [[ "$(rr2_scalar outcome <<<"$FIXTURE_OUTPUT")" == "interrupted" ]] ||
        fail "$sig: run-record outcome is not interrupted:" "$state/run.out"
    rr2_body <<<"$FIXTURE_OUTPUT" >/dev/null ||
        fail "$sig: the interrupted run emitted no complete run record:" "$state/run.out"
    grep < <(rr2_outcome p1 rc <<<"$FIXTURE_OUTPUT") -Eq '^(129|130|143)$' ||
        fail "$sig: the started row's rc is not a signal lane code (§G.2): $(rr2_outcome p1 <<<"$FIXTURE_OUTPUT")" "$state/run.out"
    [ "$(rr2_outcome p1 status <<<"$FIXTURE_OUTPUT")" = "interrupted" ] ||
        fail "$sig: the started row is not interrupted (§H.3):" "$state/run.out"
    [ "$(rr2_outcome p1 reason <<<"$FIXTURE_OUTPUT")" = "interrupted-mid-build" ] ||
        fail "$sig: the started row lacks interrupted-mid-build:" "$state/run.out"
    [ "$(rr2_outcome p2 <<<"$FIXTURE_OUTPUT")" = "p2 never-started - - interrupted-before-start" ] ||
        fail "$sig: the unlaunched row is '$(rr2_outcome p2 <<<"$FIXTURE_OUTPUT")', want never-started/interrupted-before-start (§I.3)" "$state/run.out"
    remaining_rows=$(rr2_remaining <<<"$FIXTURE_OUTPUT" | tr '\n' ' ' | sed 's/ $//')
    [ "$remaining_rows" = "$(rr2_continuation remaining <<<"$FIXTURE_OUTPUT")" ] ||
        fail "$sig: continuation remaining disagrees with the rows-derived set:" "$state/run.out"

    # Exactly ONE TERM per lane pgrp (the removed blitz logged 20), verified
    # on BOTH sides. Sender: the teardown stream names its single TERM sweep
    # once (`teardown reason=one_SIGTERM_per_lane,_shared_grace_window`, the
    # machine kv of supervisor.rs's sweep reason — supervisor.rs emits it per
    # teardown). Receiver: the stub's receipt log
    # is best-effort — the sweep's SIGKILL can preempt the trap's write when
    # the second signal skips the grace (§K.3 "kill children now"), so one
    # lost receipt is an observation skew, never a behaviour; two receipts
    # can never hide and still catch the blitz regression.
    term_sends=$(grep -c 'teardown reason=one_SIGTERM_per_lane,_shared_grace_window' "$state/run.out" 2>/dev/null)
    [[ ${term_sends:-0} -eq 1 ]] ||
        fail "$sig: the teardown sent ${term_sends:-0} TERM sweeps, want exactly one (§K.3)" "$state/run.out"
    term_count=$(grep -c '^TERM$' "$state/signals.log" 2>/dev/null)
    [[ ${term_count:-0} -le 1 ]] ||
        fail "$sig: lane pgrp received $term_count TERMs, want at most 1" "$state/signals.log"
    sleep 0.3
    if [ -n "$(find_lane_pid)" ]; then
        fail "$sig: a lane process survived the dispatcher:" "$(ps -eo pid=,args= | grep -F "$fixture" | grep -v grep)"
    fi
    if stub_lives >/dev/null; then
        fail "$sig: a stub makepkg survived the dispatcher:" "$(stub_lives)"
    fi
done

# ── 5. busy run lock: refuse pre-dispatch, never queue (§G.1 3) ────────────
echo "phase 5: busy run lock refuses before dispatch"
state="$fixture/state-busylock"
mk_env "$state" 20
run_bg "$state/a.out" "$gsa_bin" -B --leaf --no-prefetch --lanes 1 --jobs 1 p1 p2
lock_a=$disp
wait_for_file "$state/built/p1" 15 ||
    fail "lock holder never started building" "$state/a.out"
run_engine "$fixture" -B --leaf --no-prefetch --lanes 1 --jobs 1 p1 p2
{
    echo "$FIXTURE_OUTPUT"
} >"$state/b.out"
[[ $FIXTURE_RC -eq 3 ]] ||
    fail "a busy run lock must refuse with rc 3 (§G.1), got $FIXTURE_RC" "$state/b.out"
[[ "$(rr2_scalar outcome <<<"$FIXTURE_OUTPUT")" == "refused" ]] ||
    fail "the refused run's outcome scalar is not refused:" "$state/b.out"
rr2_body <<<"$FIXTURE_OUTPUT" >/dev/null ||
    fail "the refusal path emitted no full run record (§H.1):" "$state/b.out"
for pkg in p1 p2; do
    [ "$(rr2_outcome "$pkg" <<<"$FIXTURE_OUTPUT")" = "$pkg never-started - - startup-refused" ] ||
        fail "refused row for $pkg is '$(rr2_outcome "$pkg" <<<"$FIXTURE_OUTPUT")', want never-started/startup-refused:" "$state/b.out"
done
vgrep "$FIXTURE_OUTPUT" -F "$state/locks/run.lock" >/dev/null ||
    fail "the refusal does not name the run lock path:" "$state/b.out"
# the holder is a root-owned engine (W5 §B.10) — probe/signal via real sudo
/usr/bin/sudo -n kill -0 "$lock_a" 2>/dev/null ||
    fail "the refused run was queued after all — the holder is gone"
[ -e "$state/locks/run.lock" ] ||
    fail "the busy lock file disappeared"
/usr/bin/sudo -n kill -TERM "$lock_a"
end_bg

# ── 6. ONE TERM → grace → SIGKILL at the default window (§K.3, gap G5) ─────
# The lane IGNORES TERM, so nothing but the post-grace sweep can end it. The
# observable order without tuning the window: children survive the single
# TERM while the grace runs (alive at +5 s) and die with the sweep after it
# (dead well within the default 30 s + slack), having logged exactly one TERM
# receipt before the kill. Engine exit is deliberately NOT asserted here (see
# the header's known skews).
echo "phase 6: ONE TERM, grace window, then SIGKILL (default window)"
state="$fixture/state-grace"
mk_env "$state" 45
export GSA_FAKE_IGNORE_TERM=1
run_bg "$state/run.out" "$gsa_bin" -B --leaf --no-prefetch --lanes 1 --jobs 1 p1
eng=$disp
wait_for_file "$state/built/p1" 15 ||
    fail "grace run never started building" "$state/run.out"
# the engine is root (W5 §B.10) — signal it through real sudo
/usr/bin/sudo -n kill -TERM "$eng" 2>/dev/null
sleep 5
[ -n "$(find_lane_pid)" ] ||
    fail "the lane died before the grace window could expire — the single TERM must not kill a TERM-proof child"
stub_lives >/dev/null ||
    fail "the stub makepkg died before the grace window could expire"
swept=1
for ((i = 0; i < 50; i++)); do
    if [ -z "$(find_lane_pid)" ] && ! stub_lives >/dev/null; then
        swept=0
        break
    fi
    sleep 1
done
[[ $swept -eq 0 ]] ||
    fail "the TERM-proof lane/stub never died — no SIGKILL followed the grace:" "$(ps -eo pid=,args= | grep -F "$fixture" | grep -v grep)"
# ONE TERM before the kill: sender-side exactly-one (the teardown sweep line)
# + receiver-side blitz guard — see the phase 4 comment for why one lost
# receipt is an observation skew and two receipts are the blitz regression.
term_sends=$(grep -c 'teardown reason=one_SIGTERM_per_lane,_shared_grace_window' "$state/run.out" 2>/dev/null)
[[ ${term_sends:-0} -eq 1 ]] ||
    fail "the teardown sent ${term_sends:-0} TERM sweeps, want exactly one before the kill (§K.3)" "$state/run.out"
term_count=$(grep -c '^TERM$' "$state/signals.log" 2>/dev/null)
[[ ${term_count:-0} -le 1 ]] ||
    fail "the lane pgrp received $term_count TERMs, want at most one before the kill" "$state/signals.log"
# the engine is root (W5 §B.10) — signal it through real sudo
/usr/bin/sudo -n kill -KILL "$eng" 2>/dev/null
end_bg
unset GSA_FAKE_IGNORE_TERM

# ── 7. DELETED (§6 R-1): direct shim "$@" invocation ───────────────────────
# The PACMAN shim's behaviour keeps in phase 3 (the makepkg PACMAN
# observation); its fish artefact shape and passthrough source pins retire.

# ── 8. result-wire gates: identity, lost, foreign (§F.2) ───────────────────
echo "phase 8a: a bad identity can never reach the wire (seam refuses)"
state="$fixture/state-identity"
mk_env "$state" 0
res="$state/results/bad.result"
mkdir -p "$state/results"
run_engine "$fixture" --lane-job "bad id" "$res" 1
[[ $FIXTURE_RC -eq 2 ]] ||
    fail "a malformed package id must be rc 2 (producer-side codec rule), got $FIXTURE_RC" "$FIXTURE_OUTPUT"
vgrep "$FIXTURE_OUTPUT" -F "is not a valid recipe id" >/dev/null ||
    fail "the identity refusal does not name the argument:" "$FIXTURE_OUTPUT"
[ ! -e "$res" ] || fail "a refused identity published a result file"
[ ! -s "$state/makepkg.log" ] || fail "the identity refusal ran a build first:" "$(cat "$state/makepkg.log")"

echo "phase 8b: a lane that dies without publishing maps to lost (125), loudly"
state="$fixture/state-lost"
mk_env "$state" 5
( wait_for_file "$state/built/p1" 15 || exit 0
  lane=$(find_lane_pid)
  # lane children are root-owned (W5 §B.10) — signal via real sudo
  [ -n "$lane" ] && /usr/bin/sudo -n kill -KILL "$lane" ) &
watcher=$!
run_engine "$fixture" -B --leaf --no-prefetch --lanes 1 --jobs 1 p1 p2
command kill "$watcher" 2>/dev/null
wait "$watcher" 2>/dev/null
{
    echo "$FIXTURE_OUTPUT"
} >"$state/run.out"
rows=$(rr2_outcome_rows <<<"$FIXTURE_OUTPUT")
[ "$(rr2_outcome p1 <<<"$FIXTURE_OUTPUT")" = "p1 failed 125 - lane-lost" ] ||
    fail "the vanished lane's row is '$(rr2_outcome p1 <<<"$FIXTURE_OUTPUT")', want failed 125 lane-lost (the fail-closed rule):" "$state/run.out"
vgrep "$FIXTURE_OUTPUT" -F 'no usable result for p1' >/dev/null ||
    fail "the lost mapping is not reported loudly:" "$state/run.out"
# the cone of the lost package parks (§I.1) and the run is a cone-stop
# failure (§G.1 4) — derived from the rows
[ "$(rr2_outcome p2 status <<<"$FIXTURE_OUTPUT")" = "parked" ] ||
    fail "the lost package's consumer did not park:" "$state/run.out"
expected=$(printf '%s\n' "$rows" | awk '{counts[$2]++} END { if (counts["failed"] > 0) print 4; else print 0 }')
[[ $FIXTURE_RC -eq "$expected" ]] ||
    fail "lost-lane run rc=$FIXTURE_RC, want $expected (§G.1 from the rows):" "$state/run.out"
res=$(run_one_result "$state" p1)
[ -z "$res" ] || fail "the vanished lane published a result after all:" "$(cat "$res" 2>/dev/null)"

echo "phase 8c: a FOREIGN wire line is rejected, never adopted (§F.2)"
state="$fixture/state-foreignlost"
mk_env "$state" 5
( wait_for_file "$state/built/p1" 15 || exit 0
  rundir=$(ls -d "$state/runs"/*/ 2>/dev/null | head -1)
  # the run directory is engine-owned state (W5 §B.10) — plant the foreign
  # wire line through real sudo
  [ -n "$rundir" ] && printf 'v2 pX 0 1 ok\n' | /usr/bin/sudo -n tee "$rundir/p1.result" >/dev/null
  lane=$(find_lane_pid)
  # lane children are root-owned (W5 §B.10) — signal via real sudo
  [ -n "$lane" ] && /usr/bin/sudo -n kill -KILL "$lane" ) &
watcher=$!
run_engine "$fixture" -B --leaf --no-prefetch --lanes 1 --jobs 1 p1 p2
command kill "$watcher" 2>/dev/null
wait "$watcher" 2>/dev/null
{
    echo "$FIXTURE_OUTPUT"
} >"$state/run.out"
vgrep "$FIXTURE_OUTPUT" -F "foreign result: expected 'p1', got 'pX'" >/dev/null ||
    fail "the foreign identity was not rejected by name:" "$state/run.out"
[ "$(rr2_outcome p1 <<<"$FIXTURE_OUTPUT")" = "p1 failed 125 - lane-lost" ] ||
    fail "a foreign line must fail closed to lost, not become the lane's outcome: $(rr2_outcome p1 <<<"$FIXTURE_OUTPUT")" "$state/run.out"
res=$(run_one_result "$state" p1)
[ -n "$res" ] || fail "the planted foreign line vanished" "$state/run.out"
if grep -q 'unknown' "$res"; then
    fail "a result identity was fabricated for the vanished lane:" "$(cat "$res")"
fi

# ── 9. run lock: a second run refuses (never queues), a finished run frees ─
echo "phase 9: workspace run lock (refuse, never queue; released after a run)"
state="$fixture/state-runlock"
mk_env "$state" 20
run_bg "$state/a.out" "$gsa_bin" -B --leaf --no-prefetch --lanes 1 --jobs 1 p1 p2
lock_a=$disp
wait_for_file "$state/built/p1" 15 ||
    fail "lock run A never started building" "$state/a.out"
run_engine "$fixture" -B --leaf --no-prefetch --lanes 1 --jobs 1 p1 p2
{
    echo "$FIXTURE_OUTPUT"
} >"$state/b.out"
[[ $FIXTURE_RC -eq 3 ]] ||
    fail "second concurrent run was not refused with rc 3 (got $FIXTURE_RC)" "$state/b.out"
[ "$(rr2_outcome p1 reason <<<"$FIXTURE_OUTPUT")" = "startup-refused" ] ||
    fail "the second run's rows do not carry startup-refused:" "$state/b.out"
# the holder is a root-owned engine (W5 §B.10) — probe/signal via real sudo
/usr/bin/sudo -n kill -0 "$lock_a" 2>/dev/null ||
    fail "the 'concurrent' run only passed because the holder was already gone"
/usr/bin/sudo -n kill -TERM "$lock_a"
end_bg
# The flock releases with the run — observe the free within 1 s, then the run
# started right after it must proceed.
lock_free=1
for ((i = 0; i < 10; i++)); do
    /usr/bin/flock -n "$state/locks/run.lock" true 2>/dev/null && {
        lock_free=0
        break
    }
    sleep 0.1
done
[[ $lock_free -eq 0 ]] ||
    fail "run lock still held 1 s after its run ended"
mk_env "$state" 0.5
run_engine "$fixture" -B --leaf --no-prefetch --lanes 1 --jobs 1 p1 p2
{
    echo "$FIXTURE_OUTPUT"
} >"$state/c.out"
[[ $FIXTURE_RC -eq 0 ]] ||
    fail "normal run after the release failed: rc=$FIXTURE_RC" "$state/c.out"
[ "$(rr2_outcome p1 status <<<"$FIXTURE_OUTPUT")" = "succeeded" ] ||
    fail "the post-release run did not build p1:" "$state/c.out"

# ── 10. stale run lock: the flock is the authority, not the content ────────
echo "phase 10: stale run-lock semantics (dead holder never blocks)"
state="$fixture/state-stalelock"
mkdir -p "$state/locks"
printf 'pid 4194000 started 2020-01-01T00:00:00+0000\n' >"$state/locks/run.lock"
mk_env "$state" 0.5
run_engine "$fixture" -B --leaf --no-prefetch --lanes 1 --jobs 1 p1 p2
{
    echo "$FIXTURE_OUTPUT"
} >"$state/a.out"
[[ $FIXTURE_RC -eq 0 ]] ||
    fail "run over a stale lock file (dead-pid content) failed: rc=$FIXTURE_RC" "$state/a.out"
[ "$(rr2_outcome p1 reason <<<"$FIXTURE_OUTPUT")" = "ok" ] ||
    fail "stale lock-file content blocked the run:" "$state/a.out"
mk_env "$state" 20
run_bg "$state/b.out" "$gsa_bin" -B --leaf --no-prefetch --lanes 1 --jobs 1 p1 p2
lock_b=$disp
wait_for_file "$state/built/p1" 15 ||
    fail "lock run B never started building" "$state/b.out"
# the engine is root (W5 §B.10) — signal it through real sudo
/usr/bin/sudo -n kill -KILL "$lock_b"
end_bg
for ((i = 0; i < 50; i++)); do
    /usr/bin/flock -n "$state/locks/run.lock" true 2>/dev/null && break
    sleep 0.1
done
/usr/bin/flock -n "$state/locks/run.lock" true 2>/dev/null ||
    fail "run lock still held 5 s after its holder was SIGKILLed"
mk_env "$state" 1
run_engine "$fixture" -B --leaf --no-prefetch --lanes 1 --jobs 1 p1 p2
{
    echo "$FIXTURE_OUTPUT"
} >"$state/c.out"
[[ $FIXTURE_RC -eq 0 ]] ||
    fail "run after a dead holder failed: rc=$FIXTURE_RC" "$state/c.out"

# ── 11./12. dead dispatcher: the next run's sweeps clean its artifacts ─────
# §K.3's stale-artifact half: a dead run's result/park files and `.tmp.*`
# names are reaped at the next run's startup; the current run's artifacts
# survive. DEVIATIONS (header): no lane parent-liveness watchdog (a dead
# dispatcher's lane runs to completion) and the orphan-PROCESS sweep's ppid
# predicate cannot see orphans this host hands to its subreaper — both are
# recorded, not pinned.
echo "phase 11/12: dead dispatcher + startup stale-artifact sweep"
state="$fixture/state-sweep"
mk_env "$state" 8
run_bg "$state/run.out" "$gsa_bin" -B --leaf --no-prefetch --lanes 1 --jobs 1 p1
eng=$disp
wait_for_file "$state/built/p1" 15 ||
    fail "sweep run never started building" "$state/run.out"
# the engine is root (W5 §B.10) — signal it through real sudo
/usr/bin/sudo -n kill -KILL "$eng"
end_bg
# Let the dead run's lane settle on its own (however it ends — watchdog or
# build completion), then the NEXT run's startup sweep must clear the dead
# run's stale artifacts.
for ((i = 0; i < 150; i++)); do
    [ -z "$(find_lane_pid)" ] && break
    sleep 0.1
done
# Exactly the dead run's DIRECTORY before the sweep — `runs/current` (the
# §J.1 lane-state pointer) is a file and never counts.
dead_runs=$(find "$state/runs" -mindepth 1 -maxdepth 1 -type d | wc -l)
[[ $dead_runs -eq 1 ]] ||
    fail "expected exactly the dead run's directory before the sweep, saw: $(ls "$state/runs" 2>/dev/null)"
mk_env "$state" 0.5
run_engine "$fixture" -B --leaf --no-prefetch --lanes 1 --jobs 1 p3
{
    echo "$FIXTURE_OUTPUT"
} >"$state/next.out"
[[ $FIXTURE_RC -eq 0 ]] ||
    fail "the run after a dead dispatcher failed: rc=$FIXTURE_RC" "$state/next.out"
if ls "$state/runs"/*/p1.result >/dev/null 2>&1; then
    fail "the dead run's stale result survived the sweep:" "$(ls "$state/runs" 2>/dev/null)"
fi
if grep < <(find "$state/runs" -name '*.tmp.*' -print -quit) -q .; then
    fail "a stale temp name survived the sweep"
fi
[ -f "$(run_one_result "$state" p3)" ] ||
    fail "the current run's own result did not survive the sweep"
if stub_lives >/dev/null || [ -n "$(find_lane_pid)" ]; then
    fail "a fixture process survived the sweep section:" "$(ps -eo pid=,args= | grep -F "$fixture" | grep -v grep)"
fi

# ── 13. second-signal escalation: SIGKILL sweep, grace skipped (§K.3) ─────
echo "phase 13: second-signal escalation (TERM-ignoring lane, default grace)"
state="$fixture/state-escalate"
mk_env "$state" 60
export GSA_FAKE_IGNORE_TERM=1
run_bg "$state/run.out" "$gsa_bin" -B --leaf --no-prefetch --lanes 1 --jobs 1 p1
eng=$disp
wait_for_file "$state/built/p1" 15 ||
    fail "escalation run never started building" "$state/run.out"
# The first signal (HUP) latches the interrupt and starts the normal
# TERM→grace→KILL teardown — the lane IGNORES TERM, so without escalation the
# sweep would wait out the whole 30 s grace. The SECOND signal (INT) says
# NOW. Both are sent back-to-back so the two receipts land in the same
# interrupt window: same-type back-to-back signals are coalesced by the
# kernel, and near-simultaneous DIFFERENT signals race between send order and
# Linux's lowest-signal-number-first delivery, while HUP(1)→INT(2) is first
# under BOTH rules — INT is deterministically the second receipt.
# the engine is root (W5 §B.10) — signal it through real sudo
/usr/bin/sudo -n kill -HUP "$eng" 2>/dev/null
t0=$(date +%s)
/usr/bin/sudo -n kill -INT "$eng" 2>/dev/null
escalated=1
for ((i = 0; i < 100; i++)); do
    if [ -z "$(find_lane_pid)" ] && ! stub_lives >/dev/null; then
        escalated=0
        break
    fi
    sleep 0.1
done
elapsed=$(($(date +%s) - t0))
[[ $escalated -eq 0 ]] ||
    fail "the second signal did not sweep the lanes within 10 s (it waited out the grace?):" \
        "$(ps -eo pid=,args= | grep -F "$fixture" | grep -v grep)"
[[ $elapsed -le 10 ]] ||
    fail "lane teardown took ${elapsed}s after the second signal — not an immediate sweep"
# ONE TERM before the kill on the escalation path: the second signal skips
# the grace (§K.3 "kill children now"), so the receipt write races the
# SIGKILL — sender-side exactly-one + receiver-side blitz guard (phase 4).
term_sends=$(grep -c 'teardown reason=one_SIGTERM_per_lane,_shared_grace_window' "$state/run.out" 2>/dev/null)
[[ ${term_sends:-0} -eq 1 ]] ||
    fail "the teardown sent ${term_sends:-0} TERM sweeps, want exactly one before the kill (§K.3)" "$state/run.out"
term_count=$(grep -c '^TERM$' "$state/signals.log" 2>/dev/null)
[[ ${term_count:-0} -le 1 ]] ||
    fail "the lane pgrp received $term_count TERMs, want at most one before the kill" "$state/signals.log"
grep -F 'teardown reason=second_signal' "$state/run.out" >/dev/null ||
    fail "the escalation is not reported in the teardown stream:" "$state/run.out"
# the engine is root (W5 §B.10) — signal it through real sudo
/usr/bin/sudo -n kill -KILL "$eng" 2>/dev/null
end_bg
unset GSA_FAKE_IGNORE_TERM

# ── 14. foreign wire line + healthy lane: publication replaces the slot ────
echo "phase 14: a foreign result line never misclassifies the healthy lane"
state="$fixture/state-foreign-ok"
mk_env "$state" 3
( wait_for_file "$state/built/p1" 15 || exit 0
  rundir=$(ls -d "$state/runs"/*/ 2>/dev/null | head -1)
  # the run directory is engine-owned state (W5 §B.10) — plant the foreign
  # wire line through real sudo
  [ -n "$rundir" ] && printf 'v2 pX 0 1 ok\n' | /usr/bin/sudo -n tee "$rundir/p1.result" >/dev/null ) &
watcher=$!
run_engine "$fixture" -B --leaf --no-prefetch --lanes 1 --jobs 1 p1
command kill "$watcher" 2>/dev/null
wait "$watcher" 2>/dev/null
{
    echo "$FIXTURE_OUTPUT"
} >"$state/run.out"
[[ $FIXTURE_RC -eq 0 ]] ||
    fail "a foreign line broke the healthy run: rc=$FIXTURE_RC" "$state/run.out"
[ "$(rr2_outcome p1 status <<<"$FIXTURE_OUTPUT")" = "succeeded" ] ||
    fail "the healthy lane was misclassified by the foreign line: $(rr2_outcome p1 <<<"$FIXTURE_OUTPUT")" "$state/run.out"
[ "$(rr2_outcome p1 rc <<<"$FIXTURE_OUTPUT")" = "0" ] ||
    fail "the healthy lane's row rc is not 0: $(rr2_outcome p1 <<<"$FIXTURE_OUTPUT")" "$state/run.out"
[ "$(rr2_outcome p1 reason <<<"$FIXTURE_OUTPUT")" = "ok" ] ||
    fail "the healthy lane's row reason is not ok: $(rr2_outcome p1 <<<"$FIXTURE_OUTPUT")" "$state/run.out"
res=$(run_one_result "$state" p1)
codec_roundtrip p1 0 '^[0-9]+$' ok "$res"

# ── 15. result-clear refusal: fail closed, never force ─────────────────────
echo "phase 15: unremovable result slot fails closed (§F.2)"
state="$fixture/state-clear"
mk_env "$state" 0
slot="$state/slot"
mkdir -p "$slot"
printf 'not empty\n' >"$slot/junk"
run_engine "$fixture" --lane-job p1 "$slot" 1
[[ $FIXTURE_RC -eq 125 ]] ||
    fail "an unremovable result slot must fail closed to lost (125), got $FIXTURE_RC" "$FIXTURE_OUTPUT"
vgrep "$FIXTURE_OUTPUT" -F "cannot publish" >/dev/null ||
    fail "the publish refusal is not reported loudly, naming the file:" "$FIXTURE_OUTPUT"
[ -d "$slot" ] || fail "the unremovable slot disappeared — the seam must refuse, not force"
[ -f "$slot/junk" ] || fail "the slot's content was clobbered"

# ── 16. lane payload gates + `-j` pair normalisation ───────────────────────
echo "phase 16: lane payload gates (§D.1) and G10 flag grammar"
state="$fixture/state-payload"
mk_env "$state" 0
mkdir -p "$state/results"

# (a) a control character in the result path is refused BEFORE any work.
res_ctrl="$state/results/ctrl"$'\x01'".result"
run_engine "$fixture" --lane-job p1 "$res_ctrl" 1
[[ $FIXTURE_RC -eq 2 ]] ||
    fail "control-char result path rc=$FIXTURE_RC, want 2 (invocation error)" "$FIXTURE_OUTPUT"
vgrep "$FIXTURE_OUTPUT" -F 'result path' >/dev/null &&
    vgrep "$FIXTURE_OUTPUT" -F 'control characters' >/dev/null ||
    fail "missing control-character refusal:" "$FIXTURE_OUTPUT"
[ ! -e "$res_ctrl" ] || fail "a refused invocation still wrote a result file"
[ ! -s "$state/makepkg.log" ] ||
    fail "the control-char refusal ran work before refusing:" "$(cat "$state/makepkg.log")"

# (b) usage payloads: missing positionals, bad jobs — each names the argument.
run_engine "$fixture" --lane-job
[[ $FIXTURE_RC -eq 2 ]] || fail "a missing payload must be rc 2, got $FIXTURE_RC" "$FIXTURE_OUTPUT"
for bad_jobs in 0 x; do
    run_engine "$fixture" --lane-job p1 "$state/results/j.result" "$bad_jobs"
    [[ $FIXTURE_RC -eq 2 ]] || fail "jobs '$bad_jobs' must be rc 2, got $FIXTURE_RC" "$FIXTURE_OUTPUT"
    vgrep "$FIXTURE_OUTPUT" -F "jobs '$bad_jobs'" >/dev/null ||
        fail "the jobs refusal does not name the argument:" "$FIXTURE_OUTPUT"
done

# (c) G10: the `flags…` grammar is the makepkg-flag token check — forbidden
#     verification-bypass tokens, malformed tokens, empty tokens, all rc 2
#     naming the argument, and none of them reaches a build.
for bad_flag in --skipchecksums --skippgpcheck --skipinteg; do
    run_engine "$fixture" --lane-job p1 "$state/results/f.result" 1 "$bad_flag"
    [[ $FIXTURE_RC -eq 2 ]] || fail "$bad_flag must be rc 2, got $FIXTURE_RC" "$FIXTURE_OUTPUT"
    vgrep "$FIXTURE_OUTPUT" -F -- "$bad_flag" >/dev/null ||
        fail "the flag refusal does not name $bad_flag:" "$FIXTURE_OUTPUT"
    vgrep "$FIXTURE_OUTPUT" -F 'never weakened' >/dev/null ||
        fail "$bad_flag's refusal must state verification is never weakened:" "$FIXTURE_OUTPUT"
done
run_engine "$fixture" --lane-job p1 "$state/results/f.result" 1 'bad token'
[[ $FIXTURE_RC -eq 2 ]] || fail "a malformed flag token must be rc 2, got $FIXTURE_RC" "$FIXTURE_OUTPUT"
vgrep "$FIXTURE_OUTPUT" -F 'not a makepkg flag token' >/dev/null ||
    fail "the malformed-token refusal does not name the grammar:" "$FIXTURE_OUTPUT"
run_engine "$fixture" --lane-job p1 "$state/results/f.result" 1 ''
[[ $FIXTURE_RC -eq 2 ]] || fail "an empty flag token must be rc 2, got $FIXTURE_RC" "$FIXTURE_OUTPUT"
if grep < <(find "$state/results" -name '*.result' -print -quit) -q .; then
    fail "a refused --lane-job payload published a result file"
fi
[ ! -s "$state/makepkg.log" ] ||
    fail "a refused payload ran a build first:" "$(cat "$state/makepkg.log")"

# (d) `-j N` job pairs are STRIPPED from MAKEFLAGS/NINJAFLAGS with the
#     caller's other flags preserved (§K.1) — no stranded operand token, and
#     the lane's own job count travels as GSA_BUILD_JOBS output.
flags_log="$state/flags.log"
GSA_FAKE_FLAGS_LOG="$flags_log" \
    MAKEFLAGS='-j 4 --no-print-directory' NINJAFLAGS='-j 8' \
    run_engine "$fixture" --lane-job p1 "$state/results/flags.result" 3
[[ $FIXTURE_RC -eq 0 ]] ||
    fail "flags-probe lane rc=$FIXTURE_RC, want 0" "$FIXTURE_OUTPUT"
[ -s "$flags_log" ] || fail "stub makepkg never observed its flags" "$FIXTURE_OUTPUT"
mf_line=$(grep '^MAKEFLAGS=' "$flags_log" | tail -1)
nf_line=$(grep '^NINJAFLAGS=' "$flags_log" | tail -1)
jobs_line=$(grep '^GSA_BUILD_JOBS=' "$flags_log" | tail -1)
[[ $mf_line == 'MAKEFLAGS=--no-print-directory' ]] ||
    fail "MAKEFLAGS is '$mf_line', want the caller's non-job flags with -j pairs stripped (§K.1)"
[[ $nf_line == 'NINJAFLAGS=' ]] ||
    fail "NINJAFLAGS is '$nf_line', want empty after job-flag stripping (§K.1)"
[[ $jobs_line == 'GSA_BUILD_JOBS=3' ]] ||
    fail "the lane did not export its GSA_BUILD_JOBS=3 budget: '$jobs_line'"
res="$state/results/flags.result"
codec_roundtrip p1 0 '^[0-9]+$' ok "$res"

# ── 17. the interrupt abort wins over further dispatch ─────────────────────
# The ready-but-queued p3 could have started at any moment; the interrupt must
# stop dispatch before it does (the pre-dispatch latch's observable meaning —
# see the header for the unreachable zero-dispatch extreme).
echo "phase 17: the abort beats dispatch of ready work"
state="$fixture/state-abort"
mk_env "$state" 20
pidfile="$state/engine.pid"
wrap="$state/gsa-wrap"
cat >"$wrap" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$\$" > "\${GSA_FAKE_ENGINE_PID:?}"
exec "$gsa_bin" "\$@"
EOF
chmod +x "$wrap"
( wait_for_file "$pidfile" 10 || exit 0
  wait_for_file "$state/built/p1" 15 || exit 0
  # the engine is root (W5 §B.10) — signal it through real sudo
  /usr/bin/sudo -n kill -INT "$(cat "$pidfile")" 2>/dev/null ) &
watcher=$!
GSA_FAKE_ENGINE_PID="$pidfile" GSA_TEST_GSA_BIN="$wrap" \
    run_engine "$fixture" -B --leaf --no-prefetch --lanes 1 --jobs 1 p1 p3
command kill "$watcher" 2>/dev/null
wait "$watcher" 2>/dev/null
{
    echo "$FIXTURE_OUTPUT"
} >"$state/run.out"

[[ $FIXTURE_RC -eq 130 ]] ||
    fail "the aborted run exited rc=$FIXTURE_RC, want 130 (§G.1)" "$state/run.out"
rr2_body <<<"$FIXTURE_OUTPUT" >/dev/null ||
    fail "the abort path emitted no complete run record (§H.1):" "$state/run.out"
[[ "$(rr2_scalar rc <<<"$FIXTURE_OUTPUT")" == "130" ]] ||
    fail "run-record rc is $(rr2_scalar rc <<<"$FIXTURE_OUTPUT"), want 130" "$state/run.out"
[ "$(rr2_outcome p1 status <<<"$FIXTURE_OUTPUT")" = "interrupted" ] ||
    fail "the started row is not interrupted:" "$state/run.out"
[ "$(rr2_outcome p3 <<<"$FIXTURE_OUTPUT")" = "p3 never-started - - interrupted-before-start" ] ||
    fail "ready work was dispatched despite the abort: $(rr2_outcome p3 <<<"$FIXTURE_OUTPUT")" "$state/run.out"
# nothing beyond the interrupted lane was ever dispatched
[ "$(grep -c '^BUILD ' "$state/makepkg.log" 2>/dev/null)" -eq 1 ] ||
    fail "builds ran despite the pre-dispatch abort:" "$(cat "$state/makepkg.log" 2>/dev/null)"
grep -qx 'BUILD p1' "$state/makepkg.log" ||
    fail "the only dispatched build is not p1:" "$(cat "$state/makepkg.log" 2>/dev/null)"
remaining_rows=$(rr2_remaining <<<"$FIXTURE_OUTPUT" | tr '\n' ' ' | sed 's/ $//')
[ "$remaining_rows" = "$(rr2_continuation remaining <<<"$FIXTURE_OUTPUT")" ] ||
    fail "continuation remaining disagrees with the rows-derived set:" "$state/run.out"

if [ -n "$(find_lane_pid)" ] || stub_lives >/dev/null; then
    fail "a fixture process survived the battery:" "$(ps -eo pid=,args= | grep -F "$fixture" | grep -v grep)"
fi

printf 'signal-abort-lock fixture: PASS\n'
