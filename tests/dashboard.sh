#!/usr/bin/env bash
set -euo pipefail

# The dashboard is 200 lines of terminal control that the rest of the battery
# never executes: _OUTPUT_INTERACTIVE is gated on `test -t 1`, and every other
# fixture pipes the builder's output. This fixture drives the real thing under
# a pty (script(1)) with a controlled width, so these invariants are tested
# rather than assumed:
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
# Case C is the only timing-sensitive assertion in the battery: it fails if the
# builder does not return promptly after the interrupt. That is deliberate — a
# builder that waits for its lanes to finish on their own is the defect. The
# bound sits above the abort grace this case sets through the
# _LANE_STOP_GRACE_S internal seam (5 s here, 30 s by default — one TERM, then
# a deadline poll, then a single SIGKILL, the 2026-09-23 fix that stopped the
# old 50ms TERM blitz from re-interrupting a running pacman's unlock) and far
# below the stub lanes' natural ~10s runtime, so a pass proves the escalation
# killed the lanes rather than their own loop ending.
#
# The file's last section is the battery's ONE prose-rendering test (wrapped in
# a subshell like the other absorbed subjects): the run record is the
# interface and tests/run-record.sh is its test surface — this section alone
# keeps the human summary, outcome lines and notes honest.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-dashboard.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

command -v script >/dev/null || {
    printf 'script(1) is required to drive a pty\n' >&2
    exit 1
}

# A long tail line, so a wide terminal has something to truncate: at 100
# columns the row must still fit 99, which is what distinguishes a real width
# from the 80-column fallback.
make_case_workspace() { # $1 = dir, $2 = columns
    local dir=$1 cols=$2 id
    make_workspace "$dir" 2 2 low
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

rm -f "$dir/rows.txt"
printf 'dashboard fixture: PASS\n'

# ==== prose rendering ====
# The ONE place the battery asserts the human prose. Everything else asserts
# the machine block (tests/run-record.sh pins its contract) or the numbered
# listing rows; these wordings are the RENDERING adapter — the summary counts,
# the per-package outcome lines, the dry-run/listing headers, and the
# resolution/expansion notes whose behaviour the row fixtures already pin.
# A wording change breaks exactly this section, and updating it here is the
# adapter following the interface, not nine fixtures chasing prose.
(
    source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
    fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-prose-render.XXXXXX")
    trap 'rm -rf -- "$fixture"' EXIT

    fail() {
        printf 'prose rendering fixture: %s\n' "$1" >&2
        exit 1
    }

    # A chain p1 -> p2 -> p3 (p2 consumes p1; p3 consumes p2 — so a bare name
    # grows into its CONSUMERS and the failure case's counts are
    # deterministic: p1 succeeds, p2 fails, p3 is never started). The trivial
    # stubs from the helper: makepkg fails on GSA_FAKE_FAIL_PACKAGE and
    # touches an archive otherwise.
    ws=$fixture/ws
    make_workspace "$ws" 1 2 low
    for id in p1 p2 p3; do
        add_package "$ws" "$id" "$gsa_meta_any"
    done
    set_topology_record "$ws" p2 git 'p1'
    set_topology_record "$ws" p3 git 'p2'
    stub_makepkg "$ws"
    stub_sudo "$ws"
    stub_pacman "$ws"

    prose() { # [args...] -> $out
        out=$(
            PATH="$ws/bin:$PATH" \
                GSA_STATE_DIR="$ws/state" \
                GSA_FAKE_PACMAN_LOG="$ws/pacman.log" \
                GSA_CPU_THREADS=8 \
                GSA_MEMORY_GIB=16 \
                fish "$ws/build-all.fish" "$@" 2>&1
        ) || true
    }
    has() { [[ $out == *"$1"* ]] || fail "output does not render '$1': $out"; }
    hasnt() { [[ $out != *"$1"* ]] || fail "output unexpectedly renders '$1': $out"; }

    # P1 — success summary + per-package outcome line + the plan sentence.
    prose --allow-broken-rustc --no-deps --no-sync --intensity low p1 p2 p3
    has 'All builds succeeded!'
    has 'Built: 3 packages'
    grep -qE '^  ✓ p1 \([0-9]m[0-9][0-9]s\)' <<<"$out" \
        || fail "no per-package success line for p1: $out"
    grep -qE 'parallelism: [0-9]+ CPU threads, [0-9]+ GiB available, intensity low, [0-9]+ lane\(s\), normal -j[0-9]+, core -j[0-9]+' <<<"$out" \
        || fail "the parallelism sentence lost its shape: $out"

    # P2 — failure summary: heading, the five counts labels with their values,
    # the failed-package note, the resume block and its tip, and the plain-mode
    # per-package failure line.
    out=$(
        PATH="$ws/bin:$PATH" \
            GSA_STATE_DIR="$ws/state" \
            GSA_FAKE_PACMAN_LOG="$ws/pacman.log" \
            GSA_FAKE_FAIL_PACKAGE=p2 \
            GSA_CPU_THREADS=8 \
            GSA_MEMORY_GIB=16 \
            fish "$ws/build-all.fish" --allow-broken-rustc --no-deps --no-sync \
            --intensity low p1 p2 p3 2>&1
    ) || true
    has 'Build failed'
    has 'Successful builds: 1'
    has 'Failed builds:     1'
    has 'Blocked:           0'
    has 'Deferred:          0'
    has 'Remaining:         2'
    has 'note: 1 failed package(s) included'
    has 'To resume, run:'
    has '(Tip: add -s so already-built pkgs are skipped, or --skip-built to skip the built set without freshness checks.)'
    has '(Tip: --vcs-skip-tolerance N sets the -s waive threshold.)'
    grep -qE '^  ✗ p2: BUILD FAILED \(rc=1, [0-9]m[0-9][0-9]s\)' <<<"$out" \
        || fail "no per-package failure line for p2: $out"

    # P3 — dry run preview.
    prose --allow-broken-rustc --no-deps --no-sync -n p1 p2 p3
    has 'Build order (dry run):'
    has 'Total: 3 packages'

    # P4 — the selection listing and its index note.
    prose --allow-broken-rustc --no-deps --no-sync -l -g git
    has 'Selected packages in build order (3)'
    has 'Ranges index this list'

    # P5 — an over-long range clamps and says so.
    prose --allow-broken-rustc --no-deps --no-sync -n -g git 1..999
    has 'end clamped to 3 (the selection size)'

    # P6 — a case-variant reference resolves, and the substitution is
    # announced with the case rule.
    prose --allow-broken-rustc --no-deps --no-sync -n --no-deps P1
    has 'matched recipe'
    has 'case-sensitive'

    # P7 — a bare name grows into its CONSUMERS and says so; --no-deps stays
    # silent and single. p3 consumes p2, so bare p2 = p2 p3 — the same
    # "added 1 of the 2" count as the old chain growth, with the order
    # flipped: the named package first, its consumer after.
    prose --allow-broken-rustc --no-sync -n p2
    has 'consumer expansion added 1 of the 2 selected packages'
    seq7=$(sed -n '/Build order (dry run):/,/^Total:/p' <<<"$out" \
        | sed -n 's/^ *[0-9][0-9]*\. //p' | tr '\n' ' ')
    [[ $seq7 == 'p2 p3 ' ]] \
        || fail "bare p2 listed [$seq7], want [p2 p3] (its consumers in build order)"
    prose --allow-broken-rustc --no-deps --no-sync -n --no-deps p2
    hasnt 'consumer expansion added'

    printf 'prose rendering fixture: PASS (summary counts, outcome lines, headers, notes)\n'
)
