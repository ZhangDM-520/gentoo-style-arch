#!/usr/bin/env bash
set -uo pipefail

# makepkg's `-s` syncdeps runs pacman through $PACMAN OUTSIDE the builder's
# flock (run_pacman in /usr/bin/makepkg; six dep-pacmans raced the builder's
# `pacman -U` at 19:33:58 on 2026-09-23). build-all.fish answers with a
# generated $LOG_DIR/.pacman-shim (flock -x -w 300 <absolute mutex>
# /usr/bin/pacman "$@") exported as PACMAN into every lane, so dep installs
# serialise on the same mutex as `pacman -U`.
#
# Pins:
#   1. an install-mode run generates the shim at run start: mode 0755,
#      contains 'flock -x -w 300', the absolute mutex path and
#      /usr/bin/pacman, and the stub makepkg observed PACMAN = the shim;
#   2. the install itself went through run_pacman_locked (the builder mutex
#      line in the package log + sudo saw `pacman -U`);
#   3. invoking the shim directly passes "$@" through to pacman verbatim
#      (stub flock redirects the baked /usr/bin/pacman to a recorder).
#   4. (R-F17, 2026-10-04) read-only queries (-T/-Q) run UNLOCKED while a
#      transaction (-S) takes the mutex — the old shim flocked every call,
#      so a healthy queue behind a long transaction timed out a dep probe;
#   5. a flock timeout is named (`builder pacman mutex timed out`) and
#      propagates as rc 75;
#   6. an install that hits the mutex wait lands in the run record as a
#      `mutex-timeout` row instead of a generic build-failed.
#
# Lock isolation: the PATH-stub `pacman-conf` answers DBPath with a fixture
# directory, so the host's real /var/lib/pacman/db.lck is never probed. No
# GSA_* test knob is added — GSA_FAKE_* is consumed by the stubs only.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-shim-fixture.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    printf '%s\n' "$@" >&2
    exit 1
}

make_workspace "$fixture" auto auto xhigh
add_package "$fixture" p1 $'pkgver=1.0\npkgrel=1\narch=(x86_64)'
# Dynamic IgnorePkg registration target — never the host's /etc/pacman.conf
# (the battery must be non-mutating).
make_install_conf "$fixture/pacman.conf"

cat >"$fixture/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
name=$(basename "$PWD")
printf '%s\n' "${PACMAN:-}" >>"${GSA_FAKE_PACMAN_ENV_LOG:?fixture forgot GSA_FAKE_PACMAN_ENV_LOG}"
mkdir -p "${GSA_FAKE_MARKER_DIR:?}"
touch "$GSA_FAKE_MARKER_DIR/$name"
sleep "${GSA_FAKE_BUILD_SECONDS:-0.2}"
touch "$PWD/$name-1.0-1-x86_64.pkg.tar.zst"
exit 0
EOF

cat >"$fixture/bin/pacman-conf" <<'EOF'
#!/usr/bin/env bash
# DBPath oracle: never probe the host's real /var/lib/pacman/db.lck.
if [[ ${1:-} == DBPath ]]; then
    printf '%s\n' "${GSA_FAKE_DB_PATH:-/nonexistent-gsa-db}"
    exit 0
fi
exit 1
EOF

cat >"$fixture/bin/sudo" <<'EOF'
#!/usr/bin/env bash
# Password-free host stub: record the call, never touch a real database.
printf '%s\n' "$*" >>"${GSA_FAKE_SUDO_LOG:?fixture forgot GSA_FAKE_SUDO_LOG}"
exit 0
EOF

cat >"$fixture/bin/flock" <<'EOF'
#!/usr/bin/env bash
# Shim invocation probe: keep REAL flock semantics, but redirect the baked
# /usr/bin/pacman to the recorder so no real database is ever touched.
# GSA_FAKE_FLOCK_LOG records each flock invocation; GSA_FAKE_FLOCK_RC
# short-circuits with a chosen flock status (75 = mutex timeout) so no
# command ever runs behind the lock. Only the pacman MUTEX flock (file mode)
# is modeled: fd-mode `flock -n 9` is the builder's run-lock helper, which
# must keep real semantics or the run cannot start at all.
if [[ ${1:-} == -n && ${2:-} == 9 ]]; then
    exec /usr/bin/flock "$@"
fi
if [[ -n ${GSA_FAKE_FLOCK_LOG:-} ]]; then
    printf '%s\n' "$*" >>"$GSA_FAKE_FLOCK_LOG"
fi
if [[ -n ${GSA_FAKE_FLOCK_RC:-} ]]; then
    exit "$GSA_FAKE_FLOCK_RC"
fi
args=("$@")
for i in "${!args[@]}"; do
    [[ ${args[i]} == /usr/bin/pacman ]] && args[i]=$GSA_FAKE_STUB_PACMAN
done
exec /usr/bin/flock "${args[@]}"
EOF

cat >"$fixture/bin/record-pacman" <<'EOF'
#!/usr/bin/env bash
# argc|argv: the count makes word-splitting observable — a bare "$*" cannot
# tell "arg with space" from two separate args.
printf '%s\n' "$#|$*" >>"$GSA_FAKE_STUB_PACMAN_LOG"
exit 0
EOF

chmod +x "$fixture/bin/"*

state="$fixture/state"
mkdir -p "$state"
run_rc=0
run_output=$(
    env PATH="$fixture/bin:$PATH" \
        GSA_STATE_DIR="$state" \
        _IGNOREPKG_CONF="$fixture/pacman.conf" \
        GSA_FAKE_DB_PATH="$state/var/pacman" \
        GSA_FAKE_MARKER_DIR="$state/built" \
        GSA_FAKE_PACMAN_ENV_LOG="$state/pacman-env.log" \
        GSA_FAKE_SUDO_LOG="$state/sudo.log" \
        GSA_FAKE_BUILD_SECONDS=0.3 \
        fish "$fixture/build-all.fish" \
        --allow-broken-rustc --no-deps --no-sync \
        --lanes 1 --jobs 1 --install p1 2>&1
) || run_rc=$?

if [[ $run_rc -ne 0 ]]; then
    fail "install-mode run failed (rc=$run_rc)" "$run_output"
fi
if ! grep -q 'All builds succeeded' <<<"$run_output"; then
    fail "run did not report success:" "$run_output"
fi

# 1. shim generated at run start: mode, mutex wiring, absolute paths.
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

# 2. the lane exported PACMAN to makepkg, and installs used the builder mutex.
grep -qxF "$shim" "$state/pacman-env.log" ||
    fail "stub makepkg did not see PACMAN=$shim:" "$(cat "$state/pacman-env.log")"
[[ -f $state/logs/p1.log ]] ||
    fail "package log missing"
grep -q 'waiting for builder pacman mutex' "$state/logs/p1.log" ||
    fail "install did not go through run_pacman_locked (no mutex line)" \
        "$(cat "$state/logs/p1.log")"
grep -q -- '-n pacman -U' "$state/sudo.log" ||
    fail "sudo never saw the lane install:" "$(cat "$state/sudo.log" 2>/dev/null)"

# 3. direct invocation: "$@" reaches the (stubbed) pacman verbatim.
stub_log="$fixture/stub-pacman.log"
: >"$stub_log"
env PATH="$fixture/bin:$PATH" \
    GSA_FAKE_STUB_PACMAN="$fixture/bin/record-pacman" \
    GSA_FAKE_STUB_PACMAN_LOG="$stub_log" \
    "$shim" -S --noconfirm 'arg with space' 'wild*card' ||
    fail "shim invocation failed"
[[ $(cat "$stub_log") == '4|-S --noconfirm arg with space wild*card' ]] ||
    fail "shim did not pass \$@ through verbatim: '$(cat "$stub_log")'"

# 4. query/transaction split (R-F17): read-only calls never take the mutex.
# The shim's P= line is pointed at the recorder in a COPY so the query path
# (which execs pacman directly, without flock) is observable too.
echo "section 4: read-only queries bypass the transaction mutex"
qshim="$fixture/query-shim"
sed "s|^P=/usr/bin/pacman\$|P=$fixture/bin/record-pacman|" "$shim" >"$qshim"
chmod +x "$qshim"
flog="$fixture/flock.log"
qlog="$fixture/query-pacman.log"
shim_call() { # $1 = pacman-record log; rest = shim args
    local out=$1; shift
    : >"$flog"; : >"$out"
    env PATH="$fixture/bin:$PATH" \
        GSA_FAKE_STUB_PACMAN="$fixture/bin/record-pacman" \
        GSA_FAKE_STUB_PACMAN_LOG="$out" \
        GSA_FAKE_FLOCK_LOG="$flog" \
        "$qshim" "$@" ||
        fail "shim invocation failed: $*"
}

shim_call "$qlog" -T -- dep1 'dep 2'
[[ $(cat "$qlog") == '4|-T -- dep1 dep 2' ]] ||
    fail "shim -T did not pass \$@ through verbatim: '$(cat "$qlog")'"
[[ ! -s $flog ]] ||
    fail "read-only pacman -T queued on the transaction mutex:" "$(cat "$flog")"
shim_call "$qlog" --noconfirm -Q -q pkgname
[[ $(cat "$qlog") == '4|--noconfirm -Q -q pkgname' ]] ||
    fail "shim -Q did not pass \$@ through verbatim: '$(cat "$qlog")'"
[[ ! -s $flog ]] ||
    fail "read-only pacman -Q (PACMAN_OPTS-prefixed) queued on the transaction mutex:" "$(cat "$flog")"
shim_call "$qlog" -S --noconfirm pkgname
[[ -s $flog ]] ||
    fail "pacman -S transaction did NOT take the transaction mutex"
[[ $(cat "$qlog") == '3|-S --noconfirm pkgname' ]] ||
    fail "transaction args not passed verbatim: '$(cat "$qlog")'"

# 5. a mutex timeout is named by the shim and propagated as rc 75 (R-F17).
echo "section 5: flock timeout is named and propagated"
: >"$qlog"
rc=0
env PATH="$fixture/bin:$PATH" \
    GSA_FAKE_STUB_PACMAN="$fixture/bin/record-pacman" \
    GSA_FAKE_STUB_PACMAN_LOG="$qlog" \
    GSA_FAKE_FLOCK_RC=75 \
    "$qshim" -S --noconfirm pkgname >"$fixture/timeout.out" 2>&1 || rc=$?
[[ $rc -eq 75 ]] ||
    fail "shim timeout rc=$rc, want 75" "$(cat "$fixture/timeout.out")"
grep -q 'builder pacman mutex timed out' "$fixture/timeout.out" ||
    fail "shim does not name the mutex timeout:" "$(cat "$fixture/timeout.out")"
[[ ! -s $qlog ]] ||
    fail "timeout path still ran pacman: '$(cat "$qlog")'"

# 6. end-to-end (R-F17): an install that hits the builder mutex wait lands
#    in the run record as a `mutex-timeout` row — not a generic build-failed
#    — the named line reaches the package log, and NO lock/db recovery probe
#    runs on rc 75 (the db state seeded mid-run must stay unreported).
echo "section 6: mutex timeout lands as a mutex-timeout run-record row"
state2="$fixture/state-timeout"
mkdir -p "$state2"
run_rc2=0
# Seed a lock + a broken local-db entry DURING the build: preflight has
# already passed, so any probe output in the package log after the timeout
# proves the rc-75 path ran recovery probes it must not run.
(
    for _ in $(seq 1 300); do
        [[ -e $state2/built/p1 ]] && break
        sleep 0.1
    done
    mkdir -p "$state2/var/pacman/local/broken-1.0-1"
    : >"$state2/var/pacman/local/broken-1.0-1/mtree"
    : >"$state2/var/pacman/db.lck"
) &
creator=$!
run_output2=$(
    env PATH="$fixture/bin:$PATH" \
        GSA_STATE_DIR="$state2" \
        _IGNOREPKG_CONF="$fixture/pacman.conf" \
        GSA_FAKE_DB_PATH="$state2/var/pacman" \
        GSA_FAKE_MARKER_DIR="$state2/built" \
        GSA_FAKE_PACMAN_ENV_LOG="$state2/pacman-env.log" \
        GSA_FAKE_SUDO_LOG="$state2/sudo.log" \
        GSA_FAKE_BUILD_SECONDS=3 \
        GSA_FAKE_FLOCK_RC=75 \
        fish "$fixture/build-all.fish" \
        --allow-broken-rustc --no-deps --no-sync \
        --lanes 1 --jobs 1 --install p1 2>&1
) || run_rc2=$?
wait "$creator" 2>/dev/null
[[ $run_rc2 -ne 0 ]] ||
    fail "mutex-timeout run reported success:" "$run_output2"
grep -q 'builder pacman mutex timed out' "$state2/logs/p1.log" ||
    fail "package log lacks the named timeout line:" \
        "$(cat "$state2/logs/p1.log" 2>/dev/null)"
grep -Eq '^p1 failed [0-9]+ [0-9]+ mutex-timeout$' <<<"$run_output2" ||
    fail "run record lacks the mutex-timeout row:" "$run_output2"
if grep -q 'pacman database lock exists' "$state2/logs/p1.log"; then
    fail "the rc-75 path ran the lock recovery probe:" \
        "$(cat "$state2/logs/p1.log")"
fi
if grep -q 'broken entry' "$state2/logs/p1.log"; then
    fail "the rc-75 path ran the local-db recovery probe:" \
        "$(cat "$state2/logs/p1.log")"
fi

if ps -eo args= | grep -F "$fixture" | grep -v grep >/dev/null; then
    fail "a fixture process survived:" \
        "$(ps -eo args= | grep -F "$fixture" | grep -v grep)"
fi

printf 'pacman-mutex-shim fixture: PASS\n'
