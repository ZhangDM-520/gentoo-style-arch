#!/usr/bin/env bash
set -euo pipefail

# Note: this fixture leans on lane children surviving long enough to write
# their result. Under a machine-wide process storm (a 105k-file experiment
# spewing ~300k spawns) a lane can fail to fork and this fixture reports the
# run as failed — seen once, 2026-09-18. Re-run it on an idle machine before
# believing a failure here.
#
# Sudo liveness for unprivileged install runs. Lane installs run `sudo -n`
# (lane children have no tty), so the engine must decide, without ever
# hanging: is sudo still usable, and what happens when it is not? This
# fixture pins that decision — each mode is a real sudoers shape:
#
#   1. nopasswd  — the host never uses credentials (dual rule "(ALL) ALL" +
#                  "(ALL : ALL) NOPASSWD: ALL"). Stopping the run here is
#                  wrong; and the engine must never VALIDATE a credential it
#                  never uses (zero bare `sudo -v`).
#   2. cold      — nothing works without a password and no human is attached:
#                  refuse BEFORE building, not 150 s in.
#   3. expires   — the credential dies mid-run: say so ONCE, keep draining,
#                  and do not report success while packages are left unbuilt.
#   4. cold+TTY  — a terminal is attached but the policy is ALL `sudo -n`, so
#                  there is nothing to prompt for: the run must REFUSE at
#                  preflight with the same named message as 2 and never ask
#                  for a credential (pty sub-case; zero bare `sudo -v`).
#
# Flip notes (docs/gsa-fixture-migration.md row `tests/sudo-keepalive.sh`):
# argv `fish build-all.fish --allow-broken-rustc --no-deps --no-sync --lanes 2
# --jobs 2 --install p1..p4` -> `gsa -S --leaf --lanes … --jobs … p1 p2 p3 p4`
# (§B.4/§B.8; `--install` retires into `-S`, the IgnorePkg registration
# target is `--config`, gap G6; the unmirrorable `--allow-broken-rustc`/
# `--no-sync` drop — see tests/resume-command.sh's DEVIATION). rr_* / format:1
# rows -> rr2_* / format: 2. The preflight refusal is `gsa: sudo cannot
# install non-interactively` with rows `never-started - - preflight-refused`
# (§H.3) and rc 3 (§G.1) — measured on the engine, matching the inventory
# target cell exactly.
# DEVIATION 1 (keepalive poll): the fish builder kept a 150 s `sudo -v`
# refresh loop (the virtual-clock `date` stub existed to elapse it). The
# engine has NO keepalive at all — §K.3 "the builder never prompts": it
# escalates only through `sudo -n`, proves usability once at preflight
# (`sudo -n true`, crates/gsa-install/src/exec.rs `preflight_installs`) and
# detects a credential gone at TRANSACTION time (exec.rs `SudoLost`: a sudo
# failure carrying a password/prompt/no-tty signature, or a silent rc 1).
# Scenario 3's trigger therefore flips from "the refresh dies mid-run" to
# "the first transaction after the credential dies fails with a credential
# signature"; the kept behaviours (one named stop, drain, non-success, full
# record) are what the row set proves. The `date` virtual-clock stub and its
# GSA_FAKE_DATE_COUNTER knob retire with the poll.
# DEVIATION 2 ("say so ONCE" — prose pins :152-153 used at :162-260): the
# per-poll re-print cannot recur without a poll, and the engine's wording
# (`install-failed sudo credential expired and cannot be refreshed`) now
# appears in diagnostic, summary AND the row itself, so the byte count of the
# message retires as rendering (§L.3). The ONCE behaviour re-pins as data:
# exactly ONE outcome row carries the credential-loss reason.
# DEVIATION 3 (lanes): scenario 3 pins the ONCE semantics deterministically,
# so it runs `--lanes 1` (exactly one transaction follows the successful one)
# where the fish case used `--lanes 2` + long builds to outlive the poll
# window. Scenario 2 keeps `--lanes 2`.
#
# Lock isolation: the PATH-stub `pacman-conf`-less workspace never touches a
# real database — `sudo` is a stub that records and answers from
# GSA_FAKE_SUDO_MODE; `pacman` is a no-op stub. State lives under the
# fixture's own GSA_STATE_DIR (never /var/lib/gsa). No GSA_* test knob is
# added — GSA_FAKE_* is consumed by the stubs only.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-sudo-fixture.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

# ─── The engine under test: built into the fixture tree (scratch only).
# GSA_TEST_GSA_BIN, when already set to an executable, is that engine (the
# rr-v2.bash run_engine convention) and the scratch build is skipped. ──────
if [ -z "${GSA_TEST_GSA_BIN:-}" ]; then
    cargo build --offline --quiet --target-dir "$fixture/cargo" -p gsa-cli \
        --manifest-path "$gsa_repo_root/Cargo.toml" ||
        { printf 'sudo keepalive fixture: cannot build the gsa binary\n' >&2; exit 1; }
    GSA_TEST_GSA_BIN="$fixture/cargo/debug/gsa"
fi
[ -x "$GSA_TEST_GSA_BIN" ] || { printf 'sudo keepalive fixture: engine not executable: %s\n' "$GSA_TEST_GSA_BIN" >&2; exit 1; }
export GSA_TEST_ENGINE=gsa
export GSA_TEST_GSA_BIN

make_workspace "$fixture" auto auto xhigh

ids=(p1 p2 p3 p4)
for id in "${ids[@]}"; do
    add_package "$fixture" "$id" $'pkgver=1.0\npkgrel=1\narch=(x86_64)'
done

# REAL archives (staged .PKGINFO tar): the engine's install discovery reads
# each archive's own .PKGINFO and refuses an empty file `empty-list`.
cat >"$fixture/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
name=$(basename "$PWD")
mkdir -p "$GSA_FAKE_MARKER_DIR"
touch "$GSA_FAKE_MARKER_DIR/$name"
stage="$PWD/.stage-$name"
mkdir -p "$stage"
{
    printf 'pkgbase = %s\n' "$name"
    printf 'pkgname = %s\n' "$name"
    printf 'pkgver = 1.0-1\n'
    printf 'arch = x86_64\n'
} >"$stage/.PKGINFO"
tar --zstd -cf "$PWD/$name-1.0-1-x86_64.pkg.tar.zst" -C "$stage" .PKGINFO
rm -rf "$stage"
sleep "${GSA_FAKE_BUILD_SECONDS:-0.1}"
EOF

cat >"$fixture/bin/pacman" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$fixture/bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GSA_FAKE_SUDO_LOG"
case "$GSA_FAKE_SUDO_MODE" in
    nopasswd)
        # Password-free host: everything works WITHOUT a credential — but a
        # credential VALIDATION would fail (this host does not use one).
        [[ " $* " == *' -v '* ]] && exit 1
        exit 0
        ;;
    expires)
        # The credential survives the preflight probe, serves the first
        # transaction, then dies for good (machine suspended, timestamp
        # timed out, ...). The engine reads the failure as SudoLost (§K.3).
        if [[ " $* " == *' pacman '* ]]; then
            txns=0
            [[ -s $GSA_FAKE_SUDO_STATE/txns ]] && read -r txns <"$GSA_FAKE_SUDO_STATE/txns"
            txns=$((txns + 1))
            printf '%s\n' "$txns" >"$GSA_FAKE_SUDO_STATE/txns"
            ((txns <= 1)) && exit 0
            echo "sudo: a terminal is required to read the password" >&2
            exit 1
        fi
        exit 0
        ;;
    cold)
        exit 1
        ;;
esac
exit 1
EOF

chmod +x "$fixture/bin/makepkg" "$fixture/bin/pacman" "$fixture/bin/sudo"

run_rc=0
run_output=""

# One scenario run through the capture runner; the scenario knobs (state
# name, sudo mode, build length, lanes) stay fixture-side.
run_scenario() {
    local state=$1 mode=$2 build_s=${3:-0.1} lanes=${4:-2}
    mkdir -p "$fixture/state-$state"
    make_install_conf "$fixture/state-$state/pacman.conf" # this case's IgnorePkg registration target (never the host's)
    export PATH="$fixture/bin:$PATH"
    export GSA_STATE_DIR="$fixture/state-$state"
    export GSA_FAKE_SUDO_MODE="$mode"
    export GSA_FAKE_SUDO_LOG="$fixture/state-$state/sudo.log"
    export GSA_FAKE_SUDO_STATE="$fixture/state-$state"
    export GSA_FAKE_MARKER_DIR="$fixture/state-$state/built"
    export GSA_FAKE_BUILD_SECONDS="$build_s"
    run_engine "$fixture" -S --leaf \
        --config "$fixture/state-$state/pacman.conf" \
        --lanes "$lanes" --jobs 2 \
        "${ids[@]}"
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
want_all=$(printf '%s\n' "${ids[@]}")

# 1. Password-free installs must not stop the run.
run_scenario nopasswd nopasswd
if [[ $run_rc -ne 0 ]]; then
    fail "nopasswd run failed (rc=$run_rc) — password-free installs must not stop dispatch" \
        "$run_output"
fi
if [[ $(count_occurrences "$run_output" "$STOPPED") -ne 0 ]]; then
    fail "nopasswd run stopped dispatch although installs need no password" "$run_output"
fi
if [[ $(built_count nopasswd) -ne ${#ids[@]} ]]; then
    fail "nopasswd run built $(built_count nopasswd)/${#ids[@]} packages" "$run_output"
fi
if ! rr2_body <<<"$run_output" >/dev/null; then
    fail "nopasswd run emitted no complete format: 2 record:" "$run_output"
fi
if [[ $(rr2_scalar outcome <<<"$run_output") != success ]] \
    || [[ $(rr2_outcome_rows <<<"$run_output" | awk '$2 == "succeeded"' | wc -l) -ne ${#ids[@]} ]]; then
    fail "nopasswd run's record is not ${#ids[@]} succeeded rows (outcome $(rr2_scalar outcome <<<"$run_output")):" \
        "$(rr2_outcome_rows <<<"$run_output")"
fi
if grep -q -E -- '^-v$' "$fixture/state-nopasswd/sudo.log"; then
    fail "nopasswd run validated a credential it never uses: $(cat "$fixture/state-nopasswd/sudo.log")"
fi

# 2. No usable sudo and no terminal: refuse before spending build time.
run_scenario cold cold
if [[ $run_rc -ne 3 ]]; then
    fail "cold run must refuse with rc 3 (§G.1), got rc=$run_rc" "$run_output"
fi
if [[ $(count_occurrences "$run_output" "$REFUSED") -ne 1 ]]; then
    fail "cold run did not refuse exactly once:" "$run_output"
fi
if [[ $(built_count cold) -ne 0 ]]; then
    fail "cold run built $(built_count cold) package(s) before noticing sudo was unusable"
fi
if ! rr2_body <<<"$run_output" >/dev/null; then
    fail "cold run emitted no complete format: 2 record:" "$run_output"
fi
if [[ $(rr2_scalar outcome <<<"$run_output") != refused ]] ||
    [[ $(rr2_scalar rc <<<"$run_output") != 3 ]]; then
    fail "cold run's record is outcome $(rr2_scalar outcome <<<"$run_output") rc $(rr2_scalar rc <<<"$run_output"), want refused 3:" "$run_output"
fi
# The record says NOTHING started: the refusal is an outcome, not a message.
if [[ $(rr2_remaining <<<"$run_output" | tr '\n' ' ') != "${ids[*]} " ]]; then
    fail "cold run's resume set is not every package:" "$(rr2_outcome_rows <<<"$run_output")"
fi
for id in "${ids[@]}"; do
    [[ $(rr2_outcome "$id" <<<"$run_output") == "$id never-started - - preflight-refused" ]] \
        || fail "cold run's $id row is wrong: $(rr2_outcome "$id" <<<"$run_output")"
done

# 3. Credential dies mid-run: one named stop, non-zero exit, packages
# reported as remaining instead of a silent success. One lane (DEVIATION 3):
# exactly one transaction follows the successful one, so the ONCE semantics
# are deterministic.
run_scenario expires expires 0.3 1
if [[ $run_rc -ne 4 ]]; then
    fail "expired-credential run must exit 4 (cone-stop with a failure, §G.1), got rc=$run_rc" "$run_output"
fi
if ! rr2_body <<<"$run_output" >/dev/null; then
    fail "expired-credential run emitted no complete format: 2 record:" "$run_output"
fi
# "say so ONCE" is DATA (DEVIATION 2): exactly one row carries the
# credential-loss reason — the halt lands on one package.
n_credential=$(rr2_outcome_rows <<<"$run_output" | grep -c -F 'sudo credential expired' || true)
if [[ $n_credential -ne 1 ]]; then
    fail "expired-credential run named the stop in $n_credential outcome rows (want 1):" \
        "$(rr2_outcome_rows <<<"$run_output")"
fi
# "Reported as remaining" is DATA: one row per package and the resume set is
# exactly the non-succeeded rows.
if [[ $(rr2_outcome_rows <<<"$run_output" | wc -l) -ne ${#ids[@]} ]]; then
    fail "expired-credential run did not record one row per package:" "$(rr2_outcome_rows <<<"$run_output")"
fi
if [[ -z $(rr2_remaining <<<"$run_output") ]]; then
    fail "expired-credential run's resume set is empty although packages never built:" \
        "$(rr2_outcome_rows <<<"$run_output")"
fi
succeeded=$(rr2_outcome_rows <<<"$run_output" | awk '$2 == "succeeded"' | wc -l)
if [[ $(rr2_remaining <<<"$run_output" | wc -l) -ne $((${#ids[@]} - succeeded)) ]]; then
    fail "expired-credential run's resume set does not cover every non-succeeded row:" \
        "$(rr2_outcome_rows <<<"$run_output")"
fi
derived=$(rr2_remaining <<<"$run_output" | tr '\n' ' ')
derived=${derived% }
if [[ "$derived" != "$(rr2_continuation remaining <<<"$run_output")" ]]; then
    fail "remaining: disagrees with the rows-derived set [$derived]:" "$run_output"
fi
if grep -q -E -- '^-v$' "$fixture/state-expires/sudo.log"; then
    fail "expired-credential run prompted a password with no terminal attached:" \
        "$(cat "$fixture/state-expires/sudo.log")"
fi
if find "$fixture/state-expires/logs" -maxdepth 1 -name '.lane*.result*' -print -quit | grep -q .; then
    fail "lane result artifact remained after the sudo stop"
fi

# 4. Same shape as 2, but attached to a terminal: the privilege policy is ALL
#    `sudo -n` (the engine never prompts — the old interactive re-elevation is
#    gone), so a TTY must change NOTHING: refuse at preflight with the named
#    message, build nothing, and never ask for a credential (zero bare `sudo
#    -v` in the log — a prompt attempt is the regression this pins).
if command -v script >/dev/null 2>&1; then
    mkdir -p "$fixture/state-tty-cold"
    make_install_conf "$fixture/state-tty-cold/pacman.conf" # this case's IgnorePkg registration target (never the host's)
    pty_rc=0
    pty_output=$(
        script -qec "cd '$fixture' && env PATH=\"$fixture/bin:\$PATH\" \
GSA_STATE_DIR='$fixture/state-tty-cold' \
GSA_FAKE_SUDO_MODE=cold GSA_FAKE_SUDO_LOG='$fixture/state-tty-cold/sudo.log' \
GSA_FAKE_SUDO_STATE='$fixture/state-tty-cold' \
GSA_FAKE_MARKER_DIR='$fixture/state-tty-cold/built' GSA_FAKE_BUILD_SECONDS=1.2 \
'$GSA_TEST_GSA_BIN' -S --leaf --config '$fixture/state-tty-cold/pacman.conf' \
--lanes 2 --jobs 2 ${ids[*]}" /dev/null 2>&1
    ) || pty_rc=$?
    if [[ $pty_rc -ne 3 ]]; then
        fail "cold-credential TTY run must refuse with rc 3 (§G.1), got rc=$pty_rc" "$pty_output"
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
    # remains (PTY capture — the parser strips the slave's \r).
    if ! rr2_body <<<"$pty_output" >/dev/null; then
        fail "cold-credential TTY run emitted no complete format: 2 record:" "$pty_output"
    fi
    if [[ $(rr2_remaining <<<"$pty_output" | tr '\n' ' ') != "${ids[*]} " ]]; then
        fail "cold-credential TTY run's resume set is not every package:" "$(rr2_outcome_rows <<<"$pty_output")"
    fi
    for id in "${ids[@]}"; do
        [[ $(rr2_outcome "$id" <<<"$pty_output") == "$id never-started - - preflight-refused" ]] \
            || fail "cold-credential TTY run's $id row is wrong: $(rr2_outcome "$id" <<<"$pty_output")"
    done
fi

if ps -eo args= | grep -F "$fixture" | grep -v grep >/dev/null; then
    fail "lane child remained after the fixture runs"
fi

printf 'sudo keepalive fixture: PASS\n'
