#!/usr/bin/env bash
set -euo pipefail

# tests/dashboard.sh — the PTY dashboard invariants, the interrupt teardown,
# and the battery's ONE prose-rendering section (§L.5). PARTIAL gsa flip
# (docs/gsa-fixture-migration.md row `tests/dashboard.sh`, phase 2): the file
# sources BOTH libraries and drives BOTH engines — scenarios the NATIVE
# engine expresses run through tests/lib/rr-v2.bash's run_engine
# (GSA_TEST_ENGINE=gsa); scenarios it does not express yet keep their fish
# invocation byte-identical (they drive the fish dashboard under a pty, which
# is where the terminal-control contract lives at all).
#
# The fish engine's dashboard is 200 lines of terminal control that the rest
# of the battery never executes: _OUTPUT_INTERACTIVE is gated on `test -t 1`,
# and every other fixture pipes the builder's output. This fixture drives the
# real thing under a pty (script(1)) with a controlled width, so these
# invariants are tested rather than assumed:
#
#   1. the interactive path actually renders (render_dashboard runs at all);
#   2. no rendered row exceeds width-1 VISIBLE columns — the contract
#      fit_dashboard_line exists for, measured with the same
#      `string length --visible` production uses, so ANSI escapes and
#      multibyte icons are counted the way the builder counts them;
#   3. the width comes from the terminal, not the 80-column fallback;
#   4. hide-cursor and show-cursor are balanced, so a run never leaves the
#      user's terminal without a cursor;
#   5. an interrupt aborts the dashboard, restores the cursor, returns 130
#      *promptly*, and leaves no lane child behind — tested with a lane child
#      that ignores TERM, so the SIGKILL escalation is exercised rather than
#      the polite TERM.
#
# Kept fish-driven (engine gaps, measured — not preferences):
#
#   * Cases A/B + cursor balance: crates/gsa-cli/src/render.rs has no
#     width-fitting/truncation logic and no cursor control — gsa's dashboard
#     is plain lines (`lane start …`/`lane done …`, render.rs `render_event`).
#     Measured with this fixture's own PTY driver at 40/100 cols: rows 218
#     visible columns wide (no fitting at all), zero ESC[?25l/ESC[?25h
#     sequences, zero CR-ESC[2K redraws. There is no width/cursor contract
#     on the gsa side to flip to.
#   * Case C's SIGKILL-escalation half (the TERM-ignoring lane child): gsa's
#     teardown kills that child with the grace-expiry SIGKILL sweep BEFORE it
#     can publish a result, and the supervisor's interrupted/no-result path
#     then skips machine.record and loops forever
#     (crates/gsa-sched/src/supervisor.rs:704-707 `continue 'outer` without
#     the only `active -= 1`, machine.rs:187-193/:257-258; measured: run
#     still alive 300 s after the signal, lanes dead at grace expiry, no
#     result files, no record). Until that teardown hang is fixed, the
#     escalation contract keeps its fish expression; the engine-expressed
#     interrupt surface is Case D below.
#
# Case C is the battery's timing-sensitive assertion: it fails if the builder
# does not return promptly after the interrupt. That is deliberate — a
# builder that waits for its lanes to finish on their own is the defect. The
# bound sits above the abort grace this case sets through the fish engine's
# _LANE_STOP_GRACE_S internal seam (5 s here, 30 s by default — one TERM, then
# a deadline poll, then a single SIGKILL, the 2026-09-23 fix that stopped the
# old 50ms TERM blitz from re-interrupting a running pacman's unlock) and far
# below the stub lanes' natural runtime, so a pass proves the escalation
# killed the lanes rather than their own loop ending. Gap G5 (§K.3 names no
# grace knob) retires that seam for the gsa engine: Case D asserts only
# grace-insensitive outcomes and tunes nothing.
#
# The file's last section is the battery's ONE prose-rendering test (wrapped in
# a subshell like the other absorbed subjects): the run record is the
# interface and tests/run-record.sh is its test surface — this section alone
# keeps the human summary, outcome lines and notes honest. Gap G9: the v2
# contract defines NO prose wording (§I.4 lists what must be NAMED), so the
# summary assertions are presence/meaning checks derived from the record's own
# rows; the surviving wording pins are the rendering surfaces other fixtures
# delegate here (the `parallelism:` sentence — tests/scheduler-intensity.sh;
# the listing index note and substitution announcements — tests/project.sh).
# The fish-era resume block and its tips retire (gsa renders no tips; the
# continuation `command:` is the machine truth, §H.2).
#
# Stub knobs (§D.2): GSA_FAKE_LANE_MARKER/GSA_FAKE_TICKS are this file's
# historical knobs (tests/lib/rr-v2.bash table); GSA_FAKE_ENGINE_PID and
# GSA_FAKE_DEFER_PACKAGE are declared below as in tests/gsa-sched-v2.sh.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-dashboard.XXXXXX")
# root-safe cleanup: engine state under $fixture is root-owned (W5 §B.10)
trap '/usr/bin/sudo -n rm -rf -- "$fixture" 2>/dev/null || rm -rf -- "$fixture" 2>/dev/null || true' EXIT

command -v script >/dev/null || {
    printf 'script(1) is required to drive a pty\n' >&2
    exit 1
}

# Stub knobs this fixture's stubs read (§D.2 — the names are reused from
# tests/gsa-sched-v2.sh and declared per-fixture exactly as there).
rr2_stub_knob GSA_FAKE_ENGINE_PID "dashboard engine wrapper: pidfile of the engine process to signal"
rr2_stub_knob GSA_FAKE_DEFER_PACKAGE "dashboard makepkg stub: package id whose build exits 99 (deferral)"

# The engine under test for the flipped sections: scratch build only when
# GSA_TEST_GSA_BIN is not already set (the rr-v2.bash run_engine convention).
# The fish-driven sections never see it.
if [ -z "${GSA_TEST_GSA_BIN:-}" ]; then
    cargo build --offline --quiet --target-dir "$fixture/cargo" -p gsa-cli \
        --manifest-path "$gsa_repo_root/Cargo.toml" \
        || {
        printf 'cannot build the gsa binary for the fixture\n' >&2
        exit 1
    }
    GSA_TEST_GSA_BIN="$fixture/cargo/debug/gsa"
fi
gsa_bin="$GSA_TEST_GSA_BIN"
if [ ! -x "$gsa_bin" ]; then
    printf 'cargo did not produce %s\n' "$gsa_bin" >&2
    exit 1
fi
export GSA_TEST_ENGINE=gsa
export GSA_TEST_GSA_BIN="$gsa_bin"

# A long tail line, so a wide terminal has something to truncate: at 100
# columns the row must still fit 99, which is what distinguishes a real width
# from the 80-column fallback.
make_case_workspace() { # $1 = dir, $2 = columns
    local dir=$1 cols=$2 id
    make_workspace "$dir" 2 2 low
    install_fish_oracle "$dir"
    for id in p1 p2 p3; do
        add_package "$dir" "$id" "$gsa_meta_any"
    done

    cat >"$dir/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
id=$(basename "$PWD")
# Case C records every lane child so its survival can be decided by PID
# rather than by matching `ps` argv — the builder execs makepkg by its bare
# name, so a path grep only ever matches the grep itself.
if test -n "${GSA_FAKE_LANE_MARKER:-}"; then
    printf 'START %s\n' "$$" >>"$GSA_FAKE_LANE_MARKER"
fi
# A lane supervisor is fish and dies on TERM; this child does not, which is
# the case stop_lane_process' SIGKILL escalation exists for.
trap '' TERM
trap 'exit 130' INT
for i in $(seq 1 "${GSA_FAKE_TICKS:-8}"); do
    printf 'compiling %s line %s of a deliberately overlong tail line that must be truncated to the terminal width\n' "$id" "$i"
    sleep 0.05
done
: >"$PWD/$id-1.0.0-1-any.pkg.tar.zst"
exit 0
EOF
    chmod +x "$dir/bin/makepkg"

    # script(1) runs -c through the user's login shell, which is fish here and
    # rejects `VAR=value cmd`, so the command goes through a wrapper script.
    cat >"$dir/run.sh" <<EOF
#!/usr/bin/env bash
stty cols $cols rows 24
export PATH="$dir/bin:\$PATH"
export GSA_STATE_DIR="$dir/state"
export GSA_CPU_THREADS=8 GSA_MEMORY_GIB=16
export GSA_FAKE_TICKS=8
exec fish "$dir/build-all.fish" --allow-broken-rustc --no-deps --no-sync --lanes 2 p1 p2 p3
EOF
    chmod +x "$dir/run.sh"
}

# Runs the builder in a pty; captures the raw stream to $dir/out.raw and its
# exit status in RAW_RC.
run_pty() { # $1 = dir
    local dir=$1
    set +e
    TERM=xterm script -qec "$dir/run.sh" /dev/null >"$dir/out.raw" 2>&1
    RAW_RC=$?
    set -e
}

# Rows rendered through the dashboard are exactly those the builder prefixes
# with CR ESC[2K (render_dashboard emits that per row), so marking the prefix
# isolates dashboard output from ordinary banner lines that have no width
# contract.
extract_rows() { # $1 = raw file, $2 = output rows file
    local esc=$'\033'
    sed -e "s/\r${esc}\[2K/\n@@DASH@@/g" "$1" | sed -n 's/^@@DASH@@//p' >"$2"
}

# Longest VISIBLE row width, measured the way the builder measures it.
max_visible_width() { # $1 = rows file
    fish -c '
        set -l worst 0
        while read -l line
            set -l n (string length --visible -- "$line")
            if test "$n" -gt "$worst"
                set worst $n
            end
        end <"$argv[1]"
        echo $worst
    ' "$1"
}

# ─── Case A: a narrow terminal truncates every row to width-1 ───────────────
dir="$fixture/cols40"
make_case_workspace "$dir" 40
run_pty "$dir"

if ((RAW_RC != 0)); then
    printf 'cols=40: builder failed (rc=%s):\n' "$RAW_RC" >&2
    sed -n '1,40p' "$dir/out.raw" >&2
    exit 1
fi
if ! grep -q 'Progress:' "$dir/out.raw"; then
    printf 'cols=40: the dashboard never rendered:\n' >&2
    sed -n '1,40p' "$dir/out.raw" >&2
    exit 1
fi

extract_rows "$dir/out.raw" "$dir/rows.txt"
if [[ ! -s "$dir/rows.txt" ]]; then
    printf 'cols=40: no dashboard rows carried the CR ESC[2K prefix\n' >&2
    exit 1
fi
width40=$(max_visible_width "$dir/rows.txt")
if ((width40 > 39)); then
    printf 'cols=40: a rendered row is %s visible columns (limit 39):\n' "$width40" >&2
    awk 'length($0) > 39' "$dir/rows.txt" | head -5 >&2
    exit 1
fi

# ─── Case B: a wide terminal is used, not the 80-column fallback ────────────
dir="$fixture/cols100"
make_case_workspace "$dir" 100
run_pty "$dir"
if ((RAW_RC != 0)); then
    printf 'cols=100: builder failed (rc=%s)\n' "$RAW_RC" >&2
    exit 1
fi
extract_rows "$dir/out.raw" "$dir/rows.txt"
width100=$(max_visible_width "$dir/rows.txt")
if ((width100 > 99)); then
    printf 'cols=100: a rendered row is %s visible columns (limit 99)\n' "$width100" >&2
    exit 1
fi
# The 80-column fallback would cap rows at 79; the fake tail line is far longer
# than that, so anything above 79 proves the terminal width was read.
if ((width100 <= 79)); then
    printf 'cols=100: widest row is only %s columns — the dashboard used the\n' "$width100" >&2
    printf '80-column fallback instead of the terminal width\n' >&2
    exit 1
fi

# ─── Cursor balance: a run must never leave the terminal cursor hidden ──────
for label in cols40 cols100; do
    raw="$fixture/$label/out.raw"
    esc=$'\033'
    hidden=$(grep -o "${esc}\[?25l" "$raw" | wc -l)
    shown=$(grep -o "${esc}\[?25h" "$raw" | wc -l)
    if ((hidden != shown)); then
        printf '%s: cursor left in an inconsistent state (hide=%s show=%s)\n' \
            "$label" "$hidden" "$shown" >&2
        exit 1
    fi
    if ((hidden == 0)); then
        printf '%s: the dashboard never hid the cursor, so it never ran\n' "$label" >&2
        exit 1
    fi
done

# ─── Case C: an interrupt aborts the dashboard and reaps the lane children ──
#
# KEPT FISH: this is the SIGKILL-escalation scenario the gsa engine cannot
# express yet (its teardown hangs on a TERM-ignoring lane child — header,
# supervisor.rs:704-707), so the fish invocation below stays as-is; the
# engine-expressed interrupt surface (record, rows, rc 130, child drain) is
# Case D.
#
# The property under test is promptness, not merely "nothing survived". A
# lane outliving the interrupt would keep compiling for hours on a machine the
# user believes is idle, so the run must return once the abort grace expires —
# never by waiting out the lanes' natural runtime — and it must return 130
# even when a lane child ignores TERM, because stop_lane_process escalates to
# SIGKILL after the grace. Both halves are load-bearing and both were
# falsified before this assertion was trusted:
#   - making lane_processes match nothing (so no lane pid is ever signalled)
#     leaves the builder blocked in stop_lane_process' `wait` until the lanes
#     finish on their own: the run then overruns the deadline below;
#   - removing the SIGKILL escalation leaves the TERM-ignoring children alive
#     and the survivor check below fails.
# A bare "no lane survived" check passes under both injections, because the
# trailing `wait $lane_pid` reaps the lane whenever the killer does nothing.
dir="$fixture/interrupt"
make_case_workspace "$dir" 40
cat >"$dir/run.sh" <<EOF
#!/usr/bin/env bash
stty cols 40 rows 24
export PATH="$dir/bin:\$PATH"
export GSA_STATE_DIR="$dir/state"
export GSA_CPU_THREADS=8 GSA_MEMORY_GIB=16
# 200 ticks x 0.05s = ~10s natural lane runtime, deliberately LONGER than
# the grace this case sets below: the lanes must be ended by the post-grace
# SIGKILL escalation, not by their own loop running out.
export GSA_FAKE_TICKS=200
# Shorten the abort grace through the builder's internal seam (default stays
# 30 s, pinned by signal-abort-lock.sh): the contract is TERM → grace → single
# KILL, not the wall-clock length of the window, and waiting out a real 30 s
# made this the slowest fixture in the battery.
export _LANE_STOP_GRACE_S=5
export GSA_FAKE_LANE_MARKER="$dir/pids"
fish "$dir/build-all.fish" --allow-broken-rustc --no-deps --no-sync --lanes 2 p1 p2 p3 &
builder=\$!
# Wait for BOTH lanes to record themselves before interrupting: a fixed
# sleep races the dispatcher under parallel battery load, and interrupting
# before any lane starts would prove nothing (the assertion below says so
# honestly if the lanes never appear within 10s).
attempts=0
while :; do
    n=\$(wc -l <"$dir/pids" 2>/dev/null || echo 0)
    if test "\$n" -ge 2; then break; fi
    attempts=\$((attempts + 1))
    if test "\$attempts" -ge 100; then break; fi
    sleep 0.1
done
kill -INT "\$builder" 2>/dev/null
# A zombie still answers kill -0, so \"exited\" is decided the way the builder
# decides it: no such pid, or a Z state. The 20s deadline clears the 5s abort
# grace (and this case's own startup) with 2x margin for a loaded machine.
attempts=0
while :; do
    state=\$(ps -o stat= -p "\$builder" 2>/dev/null | tr -d ' ')
    if test -z "\$state" || test "\${state#*Z}" != "\$state"; then break; fi
    attempts=\$((attempts + 1))
    if test "\$attempts" -ge 200; then
        printf 'interrupt: the builder was still running 20s after SIGINT —\\n' >&2
        printf 'past the abort grace, so the lanes were never signalled\\n' >&2
        kill -KILL "\$builder" 2>/dev/null
        break
    fi
    sleep 0.1
done
wait "\$builder" 2>/dev/null
exit \$?
EOF
chmod +x "$dir/run.sh"
run_pty "$dir"

if ((RAW_RC != 130)); then
    printf 'interrupt: expected exit 130, got %s\n' "$RAW_RC" >&2
    tail -20 "$dir/out.raw" >&2
    exit 1
fi
esc=$'\033'
if ! grep -q "${esc}\[?25h" "$dir/out.raw"; then
    printf 'interrupt: the cursor was never restored (abort_dashboard did not run)\n' >&2
    exit 1
fi
if ! grep -q 'interrupted' "$dir/out.raw"; then
    printf 'interrupt: no interruption notice was printed\n' >&2
    tail -20 "$dir/out.raw" >&2
    exit 1
fi
# Baseline first: if no lane child ever ran, "none survived" would be vacuous.
if [[ ! -s "$dir/pids" ]]; then
    printf 'interrupt: no lane child recorded itself, so nothing was proven\n' >&2
    tail -20 "$dir/out.raw" >&2
    exit 1
fi
recorded=$(wc -l <"$dir/pids")
survivors=()
while read -r tag pid; do
    [[ $tag == START ]] || continue
    # `ps` exits 1 for a pid that is already gone — the outcome this case
    # wants — so the failure is absorbed rather than aborting on pipefail.
    state=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ') || state=
    if [[ -n $state && ${state#*Z} == "$state" ]]; then
        survivors+=("$pid")
    fi
done <"$dir/pids"
if ((${#survivors[@]} > 0)); then
    printf 'interrupt: %s of %s lane children survived the interrupt: %s\n' \
        "${#survivors[@]}" "$recorded" "${survivors[*]}" >&2
    ps -o pid=,ppid=,pgid=,args= -p "${survivors[@]}" >&2 2>&1 || true
    exit 1
fi

# ─── Case D (gsa): one signal mid-build → full record, rc 130, drained lanes ─
#
# The engine-expression half of the interrupt contract (§I.3/§G.1/§H.2/§K.3),
# flipped to the NATIVE engine: a SIGINT mid-build tears the run down and the
# FULL `format: 2` record is emitted with rc 130 — what started is
# `interrupted interrupted-mid-build`, what never launched is `never-started
# interrupted-before-start` (§H.3) — and no lane child survives the teardown
# (§K.3). Only grace-insensitive outcomes are asserted (gap G5: the §K.3
# grace window has no knob), so nothing here tunes a grace seam. The engine
# PID is recorded by a one-line wrapper that `exec`s gsa (the
# tests/gsa-sched-v2.sh §4 technique); a watchdog bounds the exit so the
# known teardown hang (header) names itself instead of wedging the battery.
(
    set -euo pipefail
    marker=""
    fail() {
        printf 'gsa interrupt fixture: %s\n' "$1" >&2
        if [ -n "${2:-}" ] && [ -f "$2" ]; then sed 's/^/    /' "$2" >&2; fi
        # failure path: never leave the long-running stub lanes behind
        if [ -n "$marker" ] && [ -f "$marker" ]; then
            while read -r _tag _id pid; do
                # lane children are root-owned under W5 — signal via real sudo
                /usr/bin/sudo -n kill -KILL "$pid" 2>/dev/null || true
            done <"$marker"
        fi
        exit 1
    }
    dir="$fixture/gsa-interrupt"
    ws="$dir/ws"
    make_workspace "$ws" 2 2 low
    for id in p1 p2 p3; do
        add_package "$ws" "$id" "$gsa_meta_any" git
    done
    cat >"$ws/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
id=$(basename "$PWD")
# Every lane child records itself (id + pid) so the survival check can be
# decided by PID rather than by matching `ps` argv.
printf 'START %s %s\n' "$id" "$$" >>"${GSA_FAKE_LANE_MARKER:?}"
for i in $(seq 1 "${GSA_FAKE_TICKS:-8}"); do
    printf 'compiling %s line %s of a deliberately long tail\n' "$id" "$i"
    sleep 0.05
done
: >"$PWD/$id-1.0.0-1-any.pkg.tar.zst"
exit 0
EOF
    chmod +x "$ws/bin/makepkg"
    # the lane must find THIS stub, never the host's makepkg
    export PATH="$ws/bin:$PATH"

    pidfile="$dir/engine.pid"
    wrap="$dir/gsa-wrap"
    cat >"$wrap" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$\$" >"\${GSA_FAKE_ENGINE_PID:?}"
exec "$gsa_bin" "\$@"
EOF
    chmod +x "$wrap"

    marker="$dir/pids"
    watchdog="$dir/watchdog-hang"
    export GSA_FAKE_LANE_MARKER="$marker"
    export GSA_FAKE_ENGINE_PID="$pidfile"
    # 2000 ticks x 0.05s = ~100s natural lane runtime, far beyond the
    # watchdog below: a lane alive at the survival check (or a run still
    # going at the deadline) means the teardown never reached it.
    export GSA_FAKE_TICKS=2000

    (
        # Watcher: signal the engine only once BOTH lanes are provably in
        # flight (a fixed sleep races the dispatcher under battery load —
        # interrupting before any lane starts proves nothing), then bound
        # the exit.
        for _ in $(seq 1 200); do [ -s "$pidfile" ] && break; sleep 0.05; done
        [ -s "$pidfile" ] || exit 0
        for _ in $(seq 1 200); do
            if [ -f "$marker" ]; then n=$(wc -l <"$marker"); else n=0; fi
            [ "$n" -ge 2 ] && break
            sleep 0.05
        done
        # the engine is root under W5 (run_engine's sudo) — signal it through
        # the host's REAL sudo, never the PATH stub
        /usr/bin/sudo -n kill -INT "$(cat "$pidfile")" 2>/dev/null || true
        for _ in $(seq 1 400); do
            state=$(ps -o stat= -p "$(cat "$pidfile")" 2>/dev/null | tr -d ' ') || state=
            if [ -z "$state" ] || [ "${state#*Z}" != "$state" ]; then exit 0; fi
            sleep 0.05
        done
        printf 'the engine was still running 20s after SIGINT\n' >"$watchdog"
        /usr/bin/sudo -n kill -KILL "$(cat "$pidfile")" 2>/dev/null || true
    ) &
    watcher=$!
    GSA_TEST_GSA_BIN="$wrap" run_engine "$ws" -B --leaf --lanes 2 --intensity low \
        --state-dir "$ws/state" p1 p2 p3
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
    out=$FIXTURE_OUTPUT
    printf '%s\n' "$out" >"$dir/output.txt"

    [ ! -e "$watchdog" ] || fail "gsa did not return after the interrupt ($(<"$watchdog"))" "$dir/output.txt"
    [ "$FIXTURE_RC" = 130 ] || fail "interrupted run exited $FIXTURE_RC, want 130 (§G.1):" "$dir/output.txt"
    [ "$FIXTURE_RC" = "$(rr2_scalar rc <<<"$out")" ] \
        || fail "the record's rc scalar disagrees with the process exit code:" "$dir/output.txt"
    [ "$(rr2_scalar outcome <<<"$out")" = interrupted ] \
        || fail "the record does not record outcome 'interrupted':" "$dir/output.txt"

    # the FULL record is emitted (§H.1): every section parses, the plan rows
    # are complete, and the continuation carries the resume truth (§H.2)
    rr2_body <<<"$out" >/dev/null \
        || fail "the interrupted run emitted no complete run record:" "$dir/output.txt"
    for pkg in p1 p2 p3; do
        [ -n "$(rr2_plan "$pkg" plan <<<"$out")" ] \
            || fail "the interrupted record is missing the plan row of $pkg:" "$dir/output.txt"
    done
    [ -n "$(rr2_continuation command <<<"$out")" ] \
        || fail "the interrupted record has no continuation command:" "$dir/output.txt"

    # what started vs what never launched (§I.3/§H.3), derived from the lane
    # children's own start records rather than from a pinned set
    [ -s "$marker" ] || fail "no lane child recorded itself, so nothing was proven:" "$dir/output.txt"
    started=$(awk '{ print $2 }' "$marker" | sort -u | tr '\n' ' ')
    for pkg in p1 p2 p3; do
        status=$(rr2_outcome "$pkg" status <<<"$out")
        reason=$(rr2_outcome "$pkg" reason <<<"$out")
        if [[ " $started " == *" $pkg "* ]]; then
            [ "$status" = interrupted ] \
                || fail "$pkg was in flight but is recorded $status:" "$dir/output.txt"
            [ "$reason" = interrupted-mid-build ] \
                || fail "$pkg lacks the interrupted-mid-build reason (§H.3):" "$dir/output.txt"
            grep < <(rr2_outcome "$pkg" rc <<<"$out") -Eq '^(129|130|143)$' \
                || fail "an interrupted row's rc is not a signal lane code (§F.1):" "$dir/output.txt"
        else
            [ "$status" = never-started ] \
                || fail "$pkg never started but is recorded $status:" "$dir/output.txt"
            [ "$reason" = interrupted-before-start ] \
                || fail "$pkg lacks the interrupted-before-start reason (§I.3):" "$dir/output.txt"
        fi
    done

    remaining_rows=$(rr2_remaining <<<"$out" | tr '\n' ' ' | sed 's/ $//')
    [ "$remaining_rows" = "$(rr2_continuation remaining <<<"$out")" ] \
        || fail "continuation remaining disagrees with the rows-derived set:" "$dir/output.txt"

    # teardown drained the lanes (§K.3): every recorded child is gone even
    # though its natural runtime had not elapsed
    survivors=()
    while read -r tag id pid; do
        [ "$tag" = START ] || continue
        # `ps` exits 1 for a pid that is already gone — the outcome this case
        # wants — so the failure is absorbed rather than aborting on pipefail.
        state=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ') || state=
        if [ -n "$state" ] && [ "${state#*Z}" = "$state" ]; then
            survivors+=("$pid")
        fi
    done <"$marker"
    [ "${#survivors[@]}" = 0 ] || fail "lane children survived the interrupt teardown: ${survivors[*]}"
    if ps -eo args= | grep -F "$ws" | grep -v grep >/dev/null; then
        fail "a process still references $ws after the run"
    fi
)

rm -f "$dir/rows.txt"
printf 'dashboard fixture: PASS\n'

# ==== prose rendering ====
# The ONE place the battery asserts the human prose (contract §L.5): the run
# record is the interface and tests/run-record.sh is its test surface — this
# section alone keeps the human summary and the listing/plan notes honest.
# Gap G9 (docs/gsa-fixture-migration.md §8): the v2 contract defines NO prose
# wording (§I.4 lists what must be NAMED), so the summary assertions are
# presence/meaning checks against the record's own rows — never byte-equality
# — and the surviving wording pins are the rendering surfaces other fixtures
# delegate here: the `parallelism:` sentence (tests/scheduler-intensity.sh)
# and the listing index note / substitution announcements (tests/project.sh).
# The fish-era summary counts, resume block and tips retire: the counts are
# the `format: 2` rows (labels `parked`/`deferred`, §H.3) and the
# continuation `command:` is the machine truth for resuming (§H.2) — gsa
# renders no resume block or tips. A wording change breaks exactly this
# section, and updating it here is the adapter following the interface, not
# nine fixtures chasing prose.
(
    source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
    fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-prose-render.XXXXXX")
    # root-safe cleanup: engine state under $fixture is root-owned (W5 §B.10)
    trap '/usr/bin/sudo -n rm -rf -- "$fixture" 2>/dev/null || rm -rf -- "$fixture" 2>/dev/null || true' EXIT

    fail() {
        printf 'prose rendering fixture: %s\n' "$1" >&2
        exit 1
    }

    # A chain failp -> parkA -> parkB (parkA consumes failp; parkB consumes
    # parkA) and deferp -> parkC, plus the unrelated leaf okp: ONE run
    # exercises every §I.4 class — a failure with its parked cone, a deferral
    # with its parked consumer, and unrelated success. The makepkg stub is
    # the scenario oracle: fail/defer by knob (§D.2), archive otherwise.
    ws=$fixture/ws
    make_workspace "$ws" 2 2 low
    n_pkgs=0
    for id in failp parkA parkB deferp parkC okp; do
        add_package "$ws" "$id" "$gsa_meta_any" git
        n_pkgs=$((n_pkgs + 1))
    done
    set_topology_record "$ws" parkA git failp
    set_topology_record "$ws" parkB git parkA
    set_topology_record "$ws" parkC git deferp
    cat >"$ws/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
id=$(basename "$PWD")
if [ "${GSA_FAKE_FAIL_PACKAGE:-}" = "$id" ]; then exit 1; fi
if [ "${GSA_FAKE_DEFER_PACKAGE:-}" = "$id" ]; then exit 99; fi
: >"$PWD/$id-1.0.0-1-any.pkg.tar.zst"
printf 'fake makepkg %s\n' "$PWD"
EOF
    chmod +x "$ws/bin/makepkg"
    export PATH="$ws/bin:$PATH"
    export GSA_CPU_THREADS=8 GSA_MEMORY_GIB=16

    prose() { # [args...] -> $out, $rc (the NATIVE engine via run_engine)
        run_engine "$ws" "$@"
        out=$FIXTURE_OUTPUT
        rc=$FIXTURE_RC
    }
    has() { [[ $out == *"$1"* ]] || fail "output does not render '$1': $out"; }
    hasnt() { [[ $out != *"$1"* ]] || fail "output unexpectedly renders '$1': $out"; }
    # plan_rows — the numbered rows of a listing/dry-run rendering (data: the
    # anchors ranges address, §C.3).
    plan_rows() { sed -n 's/^ *[0-9][0-9]*\. //p' <<<"$out" | tr '\n' ' ' | sed 's/ $//'; }
    # summary / row_line — the run summary's per-row lines (render.rs's
    # `· <label>: <pkg> (…` frame; the structural anchor of the §I.4 checks).
    summary() { grep '^· ' <<<"$out" || true; }
    row_line() { summary | grep -E "^· [a-z ]+: $1 \(" || true; }

    # assert_summary_agrees — §H.1/§I.4: the prose summary and the machine
    # block are views of the same rows. The summary names exactly one line
    # per outcome row, each carrying the row's status meaning and reason key
    # (the `format: 2` vocabularies, §H.3), and its outcome line is the
    # record's own outcome/rc scalars.
    assert_summary_agrees() {
        local rows n_rows n_summary pkg status rc dur reason label line
        rows=$(rr2_outcome_rows <<<"$out")
        n_rows=$(wc -l <<<"$rows")
        n_summary=$(summary | wc -l)
        [ "$n_summary" -eq "$n_rows" ] \
            || fail "the summary names $n_summary rows but the record has $n_rows (§H.1: same rows): $out"
        while read -r pkg status rc dur reason; do
            case $status in
            never-started) label='never started' ;;
            *) label=$status ;;
            esac
            line=$(row_line "$pkg")
            [ -n "$line" ] || fail "the summary does not name $pkg: $out"
            [[ $line == *"$label"* ]] \
                || fail "the summary's $pkg line lacks its status meaning '$label': $out"
            [[ $line == *"$reason"* ]] \
                || fail "the summary's $pkg line lacks its reason key '$reason' (§H.3): $out"
        done <<<"$rows"
        has "outcome: $(rr2_scalar outcome <<<"$out") (rc $(rr2_scalar rc <<<"$out"))"
    }

    # P1 — a success run's rendering: the plan sentence (the wording pin
    # tests/scheduler-intensity.sh delegates to this section) agrees with the
    # record's plan scalars, and the summary covers the rows.
    prose -B --leaf --intensity low --state-dir "$ws/state-ok" okp
    [ "$rc" = 0 ] || fail "the success run exited $rc: $out"
    rr2_body <<<"$out" >/dev/null || fail "the success run emitted no run record: $out"
    grep -qE 'parallelism: [0-9]+ CPU threads, [0-9]+ GiB available, intensity low, [0-9]+ lane\(s\), normal -j[0-9]+, core -j[0-9]+' <<<"$out" \
        || fail "the parallelism sentence lost its shape: $out"
    has "intensity $(rr2_scalar intensity <<<"$out"), $(rr2_scalar lanes <<<"$out") lane(s), normal -j$(rr2_scalar normal-jobs <<<"$out"), core -j$(rr2_scalar core-jobs <<<"$out")"
    assert_summary_agrees

    # P2 — the §I.4 loud report: one run, every class NAMED (presence and
    # meaning — gap G9 fixes no wording). rc 4 is §G.1's cone-stop code for
    # a run with >=1 failed row.
    export GSA_FAKE_FAIL_PACKAGE=failp GSA_FAKE_DEFER_PACKAGE=deferp
    prose -B --leaf --intensity low --state-dir "$ws/state" failp parkA parkB deferp parkC okp
    unset GSA_FAKE_FAIL_PACKAGE GSA_FAKE_DEFER_PACKAGE
    [ "$rc" = 4 ] || fail "the cone-stop failure run exited $rc, want 4 (§G.1): $out"
    rr2_body <<<"$out" >/dev/null || fail "the failure run emitted no run record: $out"
    assert_summary_agrees
    order=$(rr2_scalar order <<<"$out")

    failed_pkgs=$(rr2_outcome_rows <<<"$out" | awk '$2 == "failed" { print $1 }')
    deferred_pkgs=$(rr2_outcome_rows <<<"$out" | awk '$2 == "deferred" { print $1 }')
    parked_pkgs=$(rr2_outcome_rows <<<"$out" | awk '$2 == "parked" { print $1 }')
    [ -n "$failed_pkgs" ] || fail "the fixture's failing package did not fail: $out"
    [ -n "$deferred_pkgs" ] || fail "the fixture's deferring package did not defer: $out"
    [ -n "$parked_pkgs" ] || fail "the failure/deferral parked nobody: $out"

    # §I.4(1): every failed package is named with its log path (the path the
    # engine renders is the state root's logs/<pkg>.log, §J.1).
    for pkg in $failed_pkgs; do
        line=$(row_line "$pkg")
        [ -n "$line" ] || fail "the summary does not name failed $pkg: $out"
        [[ $line == *"$ws/state/logs/$pkg.log"* ]] \
            || fail "the summary names failed $pkg without its log path: $out"
    done

    # §I.4(2): the parked cone — each member named with its park reason
    # (§H.3) and the failure/deferral that parked it (derived from the rows:
    # waits-on-failed parks from the failed rows, waits-on-deferred from the
    # deferred rows).
    while read -r pkg status rc dur reason; do
        case $reason in
        waits-on-failed) parkers=$failed_pkgs ;;
        waits-on-deferred) parkers=$deferred_pkgs ;;
        *) fail "parked $pkg carries unexpected reason '$reason' (§H.3): $out" ;;
        esac
        line=$(row_line "$pkg")
        [ -n "$line" ] || fail "the summary does not name parked $pkg: $out"
        for who in $parkers; do
            [[ $line == *"$who"* ]] \
                || fail "parked $pkg is named without the $reason cause $who (§I.4: the parker): $out"
        done
    done < <(rr2_outcome_rows <<<"$out" | awk '$2 == "parked"')

    # §I.4(3): every deferred package named with its reason.
    for pkg in $deferred_pkgs; do
        line=$(row_line "$pkg")
        reason=$(rr2_outcome "$pkg" reason <<<"$out")
        [ -n "$line" ] || fail "the summary does not name deferred $pkg: $out"
        [[ $line == *"$reason"* ]] \
            || fail "deferred $pkg is named without its reason '$reason': $out"
    done

    # §H.2: the resume truth is the continuation, not prose (the fish-era
    # 'To resume, run:' block and its tips retire — gap G9). `remaining:`
    # equals the rows-derived set, and the retired `blocked` label (§H.3's
    # predecessor) never reappears.
    [ -n "$(rr2_continuation command <<<"$out")" ] \
        || fail "the failure record carries no continuation command: $out"
    remaining_rows=$(rr2_remaining <<<"$out" | tr '\n' ' ' | sed 's/ $//')
    [ "$remaining_rows" = "$(rr2_continuation remaining <<<"$out")" ] \
        || fail "continuation remaining disagrees with the rows-derived set: $out"
    hasnt 'Blocked:'

    # P3 — the dry-run plan rendering (nothing builds): the count is the
    # selection's, the rows are the build order. NOTE: a dry-run record
    # carries `lanes: -`, which rr2_body's strict integer rule rejects
    # (docs/gsa-fixture-migration.md §8 G12), so the dry-run scenarios assert
    # rendering rows only and never reach rr2_*.
    prose -B --dry-run --leaf failp parkA parkB deferp parkC okp
    [ "$rc" = 0 ] || fail "the dry run exited $rc: $out"
    has "Build order (dry run): $n_pkgs packages"
    [ "$(plan_rows)" = "$order" ] \
        || fail "the dry-run rows [$(plan_rows)] are not the record's order [$order] (§C.5: one order everywhere): $out"

    # P4 — the selection listing and its index note (`gsa -Sl`, the fish `-l`
    # successor, §B.4): the rows ARE the index map ranges address (§C.3), the
    # same one order; the header and the note are the rendering pins
    # tests/project.sh delegates to this section.
    prose -Sl @git
    [ "$rc" = 0 ] || fail "the listing exited $rc: $out"
    has "Selected packages in build order ($n_pkgs)"
    has "Ranges index this list"
    [ "$(plan_rows)" = "$order" ] \
        || fail "the listing rows [$(plan_rows)] are not the record's order [$order]: $out"

    # P5 — an over-long range clamps to the whole selection (data, as
    # tests/project.sh pins). The fish "end clamped" NOTE has no engine
    # expression — gsa clamps silently (crates/gsa-cli/src/select.rs min()s
    # the range end against the selection with no diagnostic) — so the note
    # wording retires to gap G9.
    prose -Sl @git 1..999
    [ "$rc" = 0 ] || fail "the over-long range 1..999 exited $rc: $out"
    [ "$(plan_rows)" = "$order" ] \
        || fail "1..999 did not clamp to the whole $n_pkgs-package selection: $out"

    # P6 — a case-variant reference resolves, and the substitution is
    # announced naming the given reference and its resolved recipe (the
    # resolution is data in tests/project.sh; the announcement wording is
    # this section's rendering).
    prose -B --dry-run --leaf OKP
    [ "$rc" = 0 ] || fail "the case-variant reference OKP was refused: $out"
    has "case-variant match: 'OKP' -> 'okp'"
    [ "$(plan_rows)" = okp ] || fail "OKP resolved to [$(plan_rows)], not okp: $out"

    # P7 — a bare name grows into its CONSUMERS and says so (the counts are
    # the fixture's own graph: parkA's consumer is parkB, so the closure is 2
    # with 1 added); --leaf stays silent and single.
    prose -B --dry-run parkA
    [ "$rc" = 0 ] || fail "the expansion run exited $rc: $out"
    has 'consumer expansion added 1 of the 2 selected packages'
    [ "$(plan_rows)" = "parkA parkB" ] \
        || fail "bare parkA listed [$(plan_rows)], want [parkA parkB] (its consumers in build order): $out"
    prose -B --dry-run --leaf parkA
    [ "$rc" = 0 ] || fail "the leaf run exited $rc: $out"
    hasnt 'consumer expansion added'
    [ "$(plan_rows)" = parkA ] || fail "--leaf parkA listed [$(plan_rows)], want [parkA]: $out"

    printf 'prose rendering fixture: PASS (§I.4 naming, record agreement, rendering surfaces)\n'
)
