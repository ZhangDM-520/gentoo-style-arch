#!/usr/bin/env bash
set -euo pipefail

# TTY live dashboard + pipe STATUS fixture (the ux surface, contract §L.5).
#
# PARTIAL-FLIP sibling of tests/app-group.sh's PTY sections: this fixture
# drives the NATIVE engine on a real PTY (script(1)) and pins the three run
# views the UX wave made:
#   A. TTY + human (the default): the redrawn progress box — Progress header,
#      per-lane rows with RUN-SCOPED log tails (the `<run>/<pkg>.started`
#      log-offset), spinner + last-event footer, and balanced cursor
#      hide/show (`\033[?25l` once in, `\033[?25h` once out before the record).
#   B. a human-mode non-interactive stream (PTY with TERM=dumb — `--human`
#      is retired, H2): append-only event lines + the 10 s `STATUS:` hint;
#      the retired `--human` flag itself answers a usage error (rc 2);
#      (the "is it stuck?" surface for redirected logs).
#   C. pipe + machine (default): the leveled kv stream gains NO dashboard
#      noise — no STATUS lines, no cursor sequences.
# TERM=xterm on purpose (unlike app-group's TERM=dumb for fish's DA1 queries):
# the dashboard gate is `stdout is a terminal && TERM != dumb`.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-dashboard-pty.XXXXXX")
# root-safe cleanup: engine state under $fixture is root-owned (W5 §B.10)
trap '/usr/bin/sudo -n rm -rf -- "$fixture" 2>/dev/null || rm -rf -- "$fixture" 2>/dev/null || true' EXIT

fail() {
    printf 'dashboard-pty: %s\n' "$1" >&2
    if [ -n "${2:-}" ] && [ -f "$2" ]; then
        sed 's/^/    /' "$2" >&2
    fi
    exit 1
}

ws=$fixture/ws
make_workspace "$ws" 2 2 low
add_package "$ws" p1 "$gsa_meta_any" git
add_package "$ws" p2 "$gsa_meta_any" git

# The makepkg stub is the clock: two log steps, each GSA_FAKE_BUILD_SECONDS
# (the knob shape tests/prefetch.rs already owns), so a section sizes its own
# run — 2 s proves spinner ticks, 6 s spans the 10 s STATUS window.
cat >"$ws/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -eu
id=$(basename "$PWD")
echo "step 1: preparing $id"
sleep "${GSA_FAKE_BUILD_SECONDS:-1}"
echo "step 2: building $id"
sleep "${GSA_FAKE_BUILD_SECONDS:-1}"
: >"$PWD/$id-1.0.0-1-any.pkg.tar.zst"
EOF
chmod +x "$ws/bin/makepkg"
mkdir -p "$fixture/tmp" "$ws/home"

gsa_bin=${GSA_TEST_GSA_BIN:-$(command -v gsa || true)}
[[ -x ${gsa_bin:-} ]] || fail "engine under test is not executable: ${GSA_TEST_GSA_BIN:-gsa}"
# Absolute: run_pty execs it from inside the workspace.
gsa_bin=$(readlink -f "$gsa_bin")

# run_pty SECONDS STATE-DIR [extra gsa args...] — the engine on a PTY, like
# app-group's run_pty but privileged (W5 §B.10: -B is a root mutation) and
# TERM=xterm so the dashboard gate opens (GSA_FIXTURE_TERM overrides TERM —
# section B drives the non-interactive human surface with TERM=dumb). $out
# keeps the raw PTY stream.
run_pty() {
    local secs=$1 state=$2 out=$3 term=${GSA_FIXTURE_TERM:-xterm}
    shift 3
    set +e
    timeout 90 script -qec \
        "/usr/bin/sudo -n env PATH='$ws/bin:/usr/bin:/bin' HOME='$ws/home' \
            TMPDIR='$fixture/tmp' GSA_STATE_DIR='$state' GSA_BUILD_DIR='$fixture/build' \
            GSA_RECIPES_DIR='$fixture/recipes' GSA_CPU_THREADS=8 GSA_MEMORY_GIB=16 \
            GSA_FAKE_BUILD_SECONDS='$secs' TERM='$term' \
            bash -c 'cd \"$ws\" && exec $gsa_bin -B --leaf --lanes 2 --intensity low \
                --state-dir \"$state\" $* p1 p2'" /dev/null >"$out" 2>&1
    RC=$?
    set -e
    return "$RC"
}

# run_pipe SECONDS STATE-DIR OUT [extra gsa args...] — the same run with
# stdout a pipe (the §J.3 guard mirrors tests/lib/rr-v2.bash's).
run_pipe() {
    local secs=$1 state=$2 out=$3
    shift 3
    set +e
    (cd "$ws" && timeout 90 /usr/bin/sudo -n env PATH="$ws/bin:/usr/bin:/bin" \
        HOME="$ws/home" TMPDIR="$fixture/tmp" GSA_STATE_DIR="$state" \
        GSA_BUILD_DIR="$fixture/build" GSA_RECIPES_DIR="$fixture/recipes" \
        GSA_CPU_THREADS=8 GSA_MEMORY_GIB=16 GSA_FAKE_BUILD_SECONDS="$secs" \
        "$gsa_bin" -B --leaf --lanes 2 --intensity low --state-dir "$state" "$@" p1 p2) \
        >"$out" 2>&1
    RC=$?
    set -e
    return "$RC"
}

# ─── A. the TTY box ─────────────────────────────────────────────────────────
echo "A: TTY box (progress, lanes, tails, spinner, cursor balance)"
out=$fixture/tty.out
run_pty 2 "$fixture/state-tty" "$out" || fail "the PTY run failed (rc=$RC)" "$out"
# PTY output carries \r (the slave's ONLCR) and per-row erase sequences:
# `tty.raw` keeps the ESC bytes (the cursor-balance checks read them),
# `tty.txt` is the dashboard's own sanitize — control-free content lines.
tr -d '\r' <"$out" >"$fixture/tty.raw"
sed -E 's#\x1b\[[0-9;?]*[[:alpha:]]##g' "$fixture/tty.raw" >"$fixture/tty.txt"

grep -Fq 'Progress: 2/2 started | 2 done | 0 failed | ✓ DONE' "$fixture/tty.txt" \
    || fail "the progress header never reached its DONE state:" "$out"
grep -Fq 'Lane 1: → RUNNING p1 ' "$fixture/tty.txt" \
    || fail "lane 1 never rendered its RUNNING row:" "$out"
grep -Fq '  > step 1: preparing p1' "$fixture/tty.txt" \
    || fail "lane 1's run-scoped log tail never rendered:" "$out"
grep -Fq '  · idle' "$fixture/tty.txt" \
    || fail "an idle lane never rendered its idle rows:" "$out"
grep -Fq ' Event: ' "$fixture/tty.txt" \
    || fail "the event footer never rendered:" "$out"

# The spinner advances only on the view tick: ≥2 distinct frames prove the
# ~1s heartbeat crossed a quiet build (frames: - \ | /). `|| true` keeps a
# zero-match grep from aborting the fixture silently under pipefail.
frames=$( (grep -oE '^[\\|/-] Event: ' "$fixture/tty.txt" || true) | sort -u | wc -l)
[ "$frames" -ge 2 ] \
    || fail "the spinner never advanced ($frames distinct frame(s)) — no view tick?: " "$out"

# Cursor balance: hidden exactly once on first draw, shown exactly once in
# finish() before the run record. Any imbalance leaves a dead terminal.
hides=$(grep -cF $'\033[?25l' "$fixture/tty.raw" || true)
shows=$(grep -cF $'\033[?25h' "$fixture/tty.raw" || true)
[ "$hides" = 1 ] && [ "$shows" = 1 ] \
    || fail "cursor hide/show unbalanced (hide=$hides show=$shows):" "$out"
# The 2-lane box is 10 rows (1 header + 2×4 lanes + 1 footer): the redraw
# moves the cursor up over exactly that block.
grep -qF $'\033[10A' "$fixture/tty.raw" \
    || fail "the redraw never moved the cursor up over the 10-row box:" "$out"

# ─── B. the non-interactive human surface (and the retired --human flag) ──
echo "B: dumb-TTY human event lines + STATUS hint; --human is a usage error"
out=$fixture/pipe-human.out
GSA_FIXTURE_TERM=dumb run_pty 6 "$fixture/state-human" "$out" \
    || fail "the dumb-TTY human run failed (rc=$RC)" "$out"
grep -Fq '→ started p1 -j2' "$out" \
    || fail "the human event lines are gone:" "$out"
grep -Eq '  STATUS: lane 1: p1 \([0-9]+s\) \| lane 2: p2 \([0-9]+s\)' "$out" \
    || fail "the 10 s STATUS hint never fired on the human stream:" "$out"
if grep -qF $'\033[' "$out"; then
    fail "the non-interactive human stream gained cursor sequences:" "$out"
fi
out=$fixture/human-flag.out
run_pipe 1 "$fixture/state-human-flag" "$out" --human || true
[ "$RC" -eq 2 ] \
    || fail "the retired --human flag must answer rc 2, got rc=$RC:" "$out"
grep -Fq "unknown flag '--human'" "$out" \
    || fail "the refusal must name the retired flag:" "$out"

# ─── C. the machine stream stays clean ─────────────────────────────────────
echo "C: machine pipe gains no dashboard noise"
out=$fixture/pipe-machine.out
run_pipe 1 "$fixture/state-machine" "$out" \
    || fail "the machine pipe run failed (rc=$RC)" "$out"
grep -Fq 'INFO lane-start pkg=p1' "$out" \
    || fail "the machine kv stream is gone:" "$out"
if grep -Fq 'STATUS:' "$out"; then
    fail "the machine stream gained a STATUS hint:" "$out"
fi
if grep -qF $'\033[' "$out"; then
    fail "the machine stream gained cursor sequences:" "$out"
fi

printf 'dashboard-pty fixture: PASS (TTY box, human STATUS, machine purity)\n'
