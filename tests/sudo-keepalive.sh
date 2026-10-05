#!/usr/bin/env bash
set -euo pipefail

# Note: this fixture leans on the dispatcher's 0.5 s polling and on lane
# children surviving long enough to write their result. Under a machine-wide
# process storm (a 105k-file experiment spewing ~300k spawns) a lane can fail to
# fork and this fixture reports the run as failed — seen once, 2026-09-18.
# Re-run it on an idle machine before believing a failure here.
#
# Sudo liveness for unprivileged -i runs. Lane installs run `sudo -n` (lane
# children have no tty), so the dispatcher must decide, without ever hanging:
# is sudo still usable, and what happens when it is not? This fixture pins
# that decision — each mode is a real sudoers shape:
#
#   1. nopasswd  — `sudo -v` can never refresh a credential this host does not
#                  use, yet every install is password-free (dual rule
#                  "(ALL) ALL" + "(ALL : ALL) NOPASSWD: ALL"). Stopping the
#                  run here is wrong.
#   2. cold      — nothing works without a password and no human is attached:
#                  refuse BEFORE building, not 150 s in.
#   3. expires   — the credential dies mid-run: say so ONCE (the per-poll
#                  re-print spammed the terminal), keep draining, and do not
#                  report success while packages are left unbuilt.
#   4. cold+TTY  — a terminal is attached but the policy is ALL `sudo -n`, so
#                  there is nothing to prompt for: the run must REFUSE at
#                  preflight with the same named message as 2 and never ask
#                  for a credential (pty sub-case; zero bare `sudo -v`).
#
# The builder's keepalive interval is 150 s of real time; the fake `date` in
# the fixture bin advances a virtual clock 300 s per call, so that interval
# elapses in a run that lasts seconds and no test knob is added to the builder.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-sudo-fixture.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

make_workspace "$fixture" auto auto xhigh

ids=(p1 p2 p3 p4)
for id in "${ids[@]}"; do
    add_package "$fixture" "$id" $'pkgver=1.0\npkgrel=1\narch=(x86_64)'
done

cat >"$fixture/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
name=$(basename "$PWD")
mkdir -p "$GSA_FAKE_MARKER_DIR"
touch "$GSA_FAKE_MARKER_DIR/$name"
touch "$PWD/$name-1.0-1-x86_64.pkg.tar.zst"
sleep "${GSA_FAKE_BUILD_SECONDS:-0.1}"
EOF

cat >"$fixture/bin/pacman" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$fixture/bin/date" <<'EOF'
#!/usr/bin/env bash
# Virtual clock: 300 s per call, so the builder's 150 s sudo keepalive
# interval elapses inside a fixture that runs for seconds.
set -uo pipefail
if [[ ${1:-} == '+%s' ]]; then
    : "${GSA_FAKE_DATE_COUNTER:?fixture forgot to set GSA_FAKE_DATE_COUNTER}"
    # Serialize read-modify-write under flock: dispatcher and lane children
    # call this concurrently, and an unguarded truncate+write let a reader
    # observe an empty file, reset the counter to 1, and produce negative
    # durations that lane_result_valid rejected as malformed (rc=125).
    exec 9>>"$GSA_FAKE_DATE_COUNTER"
    flock -x 9
    ticks=0
    [[ -s $GSA_FAKE_DATE_COUNTER ]] && read -r ticks <"$GSA_FAKE_DATE_COUNTER"
    ticks=$((ticks + 1))
    printf '%s\n' "$ticks" >"$GSA_FAKE_DATE_COUNTER"
    flock -u 9
    exec 9>&-
    printf '%s\n' "$((1700000000 + ticks * 300))"
    exit 0
fi
exec /usr/bin/date "$@"
EOF

cat >"$fixture/bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GSA_FAKE_SUDO_LOG"
case "$GSA_FAKE_SUDO_MODE" in
    nopasswd)
        [[ " $* " == *' pacman '* ]] && exit 0
        exit 1
        ;;
    expires)
        # The credential survives one refresh, then dies for good (the machine
        # was suspended, the timestamp timed out, ...).
        if [[ " $* " == *' -v '* ]]; then
            validations=0
            [[ -s $GSA_FAKE_SUDO_STATE/validations ]] &&
                read -r validations <"$GSA_FAKE_SUDO_STATE/validations"
            validations=$((validations + 1))
            printf '%s\n' "$validations" >"$GSA_FAKE_SUDO_STATE/validations"
            ((validations <= 2)) && exit 0
        fi
        exit 1
        ;;
    cold)
        exit 1
        ;;
esac
exit 1
EOF

chmod +x "$fixture/bin/makepkg" "$fixture/bin/pacman" "$fixture/bin/date" "$fixture/bin/sudo"

run_rc=0
run_output=""

# One scenario run through the helper's capture; the scenario knobs (state
# name, sudo mode, build length) stay fixture-side.
run_scenario() {
    local state=$1 mode=$2 build_s=${3:-1.2}
    mkdir -p "$fixture/state-$state"
    make_install_conf "$fixture/state-$state/pacman.conf" # this case's IgnorePkg registration target (never the host's)
    run_builder env \
        PATH="$fixture/bin:$PATH" \
        GSA_STATE_DIR="$fixture/state-$state" \
        _IGNOREPKG_CONF="$fixture/state-$state/pacman.conf" \
        GSA_FAKE_SUDO_MODE="$mode" \
        GSA_FAKE_SUDO_LOG="$fixture/state-$state/sudo.log" \
        GSA_FAKE_SUDO_STATE="$fixture/state-$state" \
        GSA_FAKE_DATE_COUNTER="$fixture/state-$state/clock" \
        GSA_FAKE_MARKER_DIR="$fixture/state-$state/built" \
        GSA_FAKE_BUILD_SECONDS="$build_s" \
        fish "$fixture/build-all.fish" \
        --allow-broken-rustc --no-deps --no-sync \
        --lanes 2 --jobs 2 --install "${ids[@]}"
    run_output=$FIXTURE_OUTPUT
    run_rc=$FIXTURE_RC
}

fail() {
    printf '%s\n' "$@" >&2
    exit 1
}

count_occurrences() {
    printf '%s\n' "$1" | grep -c -F -- "$2" || true
}

built_count() {
    find "$fixture/state-$1/built" -maxdepth 1 -type f 2>/dev/null | wc -l
}

STOPPED='cannot be refreshed'
REFUSED='cannot install non-interactively'

# 1. Password-free installs must not stop the run: `sudo -v` refuses, every
#    install works.
run_scenario nopasswd nopasswd
if [[ $run_rc -ne 0 ]]; then
    fail "nopasswd run failed (rc=$run_rc) — password-free installs must not stop dispatch" \
        "$run_output"
fi
if [[ $(count_occurrences "$run_output" "$STOPPED") -ne 0 ]]; then
    fail "nopasswd run stopped dispatch although installs need no password" "$run_output"
fi
if [[ $(built_count nopasswd) -ne 4 ]]; then
    fail "nopasswd run built $(built_count nopasswd)/4 packages" "$run_output"
fi
if [[ $(rr_scalar outcome <<<"$run_output") != success ]] \
    || [[ $(rr_rows <<<"$run_output" | awk '$2 == "succeeded"' | wc -l) -ne 4 ]]; then
    fail "nopasswd run's record is not 4 succeeded rows (outcome $(rr_scalar outcome <<<"$run_output")):" \
        "$(rr_rows <<<"$run_output")"
fi
if grep -q -E -- '^-v$' "$fixture/state-nopasswd/sudo.log"; then
    fail "nopasswd run validated a credential it never uses: $(cat "$fixture/state-nopasswd/sudo.log")"
fi

# 2. No usable sudo and no terminal: refuse before spending build time.
run_scenario cold cold
if [[ $run_rc -eq 0 ]]; then
    fail "cold run reported success without usable sudo" "$run_output"
fi
if [[ $(count_occurrences "$run_output" "$REFUSED") -ne 1 ]]; then
    fail "cold run did not refuse exactly once:" "$run_output"
fi
if [[ $(built_count cold) -ne 0 ]]; then
    fail "cold run built $(built_count cold) package(s) before noticing sudo was unusable"
fi
# The record says NOTHING started: the refusal is an outcome, not a message.
want_all=$(printf '%s\n' "${ids[@]}")
if [[ $(rr_remaining <<<"$run_output") != "$want_all" ]]; then
    fail "cold run's resume set is not every package:" "$(rr_rows <<<"$run_output")"
fi
for id in "${ids[@]}"; do
    [[ $(rr_row "$id" <<<"$run_output") == "$id never-started - - preflight-refused" ]] \
        || fail "cold run's $id row is wrong: $(rr_row "$id" <<<"$run_output")"
done

# 3. Credential dies mid-run: one message, non-zero exit, packages reported
#    as remaining instead of a silent "All builds succeeded!".
# A long first wave keeps lanes busy while the dispatcher notices: the
# pre-per-poll re-print was only visible because package builds outlive it.
run_scenario expires expires 3
if [[ $run_rc -eq 0 ]]; then
    fail "expired-credential run reported success with unbuilt packages" "$run_output"
fi
if [[ $(count_occurrences "$run_output" "$STOPPED") -ne 1 ]]; then
    fail "expired-credential run printed the stop message $(count_occurrences "$run_output" "$STOPPED")x (want 1)" \
        "$run_output"
fi
# "Reported as remaining" is DATA: one row per package and the resume set is
# exactly the non-succeeded rows (which siblings finished before the stop is
# timing; that they are all accounted for is not).
if [[ $(rr_rows <<<"$run_output" | wc -l) -ne ${#ids[@]} ]]; then
    fail "expired-credential run did not record one row per package:" "$(rr_rows <<<"$run_output")"
fi
if [[ -z $(rr_remaining <<<"$run_output") ]]; then
    fail "expired-credential run's resume set is empty although packages never built:" \
        "$(rr_rows <<<"$run_output")"
fi
succeeded=$(rr_rows <<<"$run_output" | awk '$2 == "succeeded"' | wc -l)
if [[ $(rr_remaining <<<"$run_output" | wc -l) -ne $((${#ids[@]} - succeeded)) ]]; then
    fail "expired-credential run's resume set does not cover every non-succeeded row:" \
        "$(rr_rows <<<"$run_output")"
fi
if grep -q -E -- '^-v$' "$fixture/state-expires/sudo.log"; then
    fail "expired-credential run prompted a password with no terminal attached:" \
        "$(cat "$fixture/state-expires/sudo.log")"
fi
if find "$fixture/state-expires/logs" -maxdepth 1 -name '.lane*.result*' -print -quit | grep -q .; then
    fail "lane result artifact remained after the sudo stop"
fi

# 4. Same shape as 2, but attached to a terminal: the privilege policy is ALL
#    `sudo -n` (the builder never prompts — the old interactive re-elevation is
#    gone), so a TTY must change NOTHING: refuse at preflight with the named
#    message, build nothing, and never ask for a credential (zero bare `sudo
#    -v` in the log — a prompt attempt is the regression this pins).
if command -v script >/dev/null 2>&1; then
    mkdir -p "$fixture/state-tty-cold"
    make_install_conf "$fixture/state-tty-cold/pacman.conf" # this case's IgnorePkg registration target (never the host's)
    pty_rc=0
    pty_output=$(
        script -qec "PATH=\"$fixture/bin:\$PATH\" GSA_STATE_DIR='$fixture/state-tty-cold' \
GSA_FAKE_SUDO_MODE=cold GSA_FAKE_SUDO_LOG='$fixture/state-tty-cold/sudo.log' \
GSA_FAKE_SUDO_STATE='$fixture/state-tty-cold' GSA_FAKE_DATE_COUNTER='$fixture/state-tty-cold/clock' \
GSA_FAKE_MARKER_DIR='$fixture/state-tty-cold/built' GSA_FAKE_BUILD_SECONDS=1.2 \
_IGNOREPKG_CONF='$fixture/state-tty-cold/pacman.conf' \
fish '$fixture/build-all.fish' --allow-broken-rustc --no-deps --no-sync \
--lanes 2 --jobs 2 --install ${ids[*]}" /dev/null 2>&1
    ) || pty_rc=$?
    if [[ $pty_rc -eq 0 ]]; then
        fail "cold-credential TTY run succeeded although nothing can install" "$pty_output"
    fi
    if [[ $(count_occurrences "$pty_output" "$REFUSED") -ne 1 ]]; then
        fail "cold-credential TTY run did not refuse exactly once:" "$pty_output"
    fi
    if [[ $pty_output != *'sudo cannot install non-interactively'* ]]; then
        fail "cold-credential TTY run lacks the named refusal text:" "$pty_output"
    fi
    if [[ $(count_occurrences "$pty_output" "$STOPPED") -ne 0 ]]; then
        fail "cold-credential TTY run stopped dispatch instead of refusing up front" "$pty_output"
    fi
    if grep -q -E -- '^-v$' "$fixture/state-tty-cold/sudo.log"; then
        fail "cold-credential TTY run asked for a credential (policy is all sudo -n):" \
            "$(cat "$fixture/state-tty-cold/sudo.log")"
    fi
    if [[ $(built_count tty-cold) -ne 0 ]]; then
        fail "cold-credential TTY run built $(built_count tty-cold) package(s) before refusing"
    fi
    # The record carries the refusal as data: nothing started, everything
    # remains (PTY capture — the parsers strip the slave's \r).
    want_all=$(printf '%s\n' "${ids[@]}")
    if [[ $(rr_remaining <<<"$pty_output") != "$want_all" ]]; then
        fail "cold-credential TTY run's resume set is not every package:" "$(rr_rows <<<"$pty_output")"
    fi
    for id in "${ids[@]}"; do
        [[ $(rr_row "$id" <<<"$pty_output") == "$id never-started - - preflight-refused" ]] \
            || fail "cold-credential TTY run's $id row is wrong: $(rr_row "$id" <<<"$pty_output")"
    done
fi

if ps -eo args= | grep -F "$fixture" | grep -v grep >/dev/null; then
    fail "lane child remained after the fixture runs"
fi

printf 'sudo keepalive fixture: PASS\n'
