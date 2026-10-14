#!/usr/bin/env bash
set -uo pipefail

# makepkg's `-s` syncdeps runs pacman through $PACMAN OUTSIDE the builder's
# flock (run_pacman in /usr/bin/makepkg; six dep-pacmans raced the builder's
# `pacman -U` at 19:33:58 on 2026-09-23). The engine answers with a generated
# PACMAN shim exported into every lane, so dep installs serialise on the same
# mutex as `pacman -U`.
#
# Pins (flip notes below):
#   1. an install-mode run generates the shim at run start: mode 0755, a
#      flock line naming the absolute mutex path and /usr/bin/pacman, and
#      `"$@"` passthrough; the stub makepkg observed PACMAN = the shim;
#   2. the install itself serialises on that mutex (a live holder on the
#      mutex delays the transaction until release) and sudo saw `pacman -U`;
#   3. invoking the shim directly passes "$@" through to pacman verbatim
#      (stub flock redirects the baked /usr/bin/pacman to a recorder);
#   4. (R-F17, 2026-10-04) read-only queries (-T/-Q) run UNLOCKED while a
#      transaction (-S) takes the mutex — the old shim flocked every call,
#      so a healthy queue behind a long transaction timed out a dep probe;
#   5. a flock failure is propagated verbatim (75 stays 75, pacman never
#      runs) and a rc-1 failure is NAMED by the shim;
#   6. (FISH-DRIVEN, see DEVIATION 2) an install that hits the mutex wait
#      lands in the run record as a `mutex-timeout` row instead of a generic
#      build-failed.
#
# Flip notes (docs/gsa-fixture-migration.md row `tests/pacman-mutex-shim.sh`):
# argv `fish build-all.fish --allow-broken-rustc --no-deps --no-sync --lanes 1
# --jobs 1 --install p1` -> `gsa -S --leaf --lanes 1 --jobs 1 p1` (§B.4/§B.8);
# the IgnorePkg registration target is `--config <conf>` (gap G6). The
# shim's fish-era spellings re-pin to the engine's (crates/gsa-build/src/shim.rs):
# `$STATE_DIR/logs/.pacman-shim` -> `$STATE_DIR/locks/pacman-shim` (§J.1 puts
# the mutex and its shim under `locks/`), `flock -x -w 300 <mutex>
# /usr/bin/pacman "$@"` -> `flock -x -w 600 <mutex> sudo -n "$P" "$@"` (the
# shim itself runs transactions through `sudo -n`, §K.3), and the mutex file
# `.pacman-install.lock` -> `locks/pacman-mutex`. The `waiting for builder
# pacman mutex` package-log prose (:153-154) retires as rendering (§L.3):
# serialisation re-pins as the live holder probe in section 2, and the
# `run_pacman_locked` source shape is R-1 (no engine source to grep).
# DEVIATION 1 (section 5 naming): the fish shim named a flock timeout
# (`builder pacman mutex timed out`) and mapped it to rc 75. The engine shim
# propagates flock's exit status VERBATIM and names only rc-1 failures
# (`gsa pacman shim: transaction failed (sudo -n never prompts)`) — there is
# no timeout-specific wording and no 75 mapping to pin. The kept behaviour
# (a shim failure propagates and runs no pacman) re-pins against the engine's
# own message; the fish wording's meaning rides the `mutex-timeout` reason of
# the run-record row (section 6 / DEVIATION 2).
# DEVIATION 2 (section 6, inventory cell "REWRITE: rr-format1 1 (:264 row
# regex — reason `mutex-timeout`, gap G3)"): the `mutex-timeout` run-record
# row has NO engine trigger at fixture scale — the transaction mutex wait is
# a hard-coded 600 s poll (crates/gsa-install/src/exec.rs `acquire_mutex`,
# `Duration::from_secs(600)`) with no knob or seam, and the shim path turns a
# flock failure into an ordinary `build-failed` build outcome. The end-to-end
# row pin stays fish-driven (the local-db-repair pattern), against the
# still-shipped fish builder this fixture's workspace carries.
# DEVIATION 3 (inventory argv cell `gsa -S --leaf --no-sync …`): `--no-sync`
# is parse-and-refuse on the engine today (rc 2, deferred_flags disposition)
# and its live wiring belongs to the concurrent sync stream; the scenario has
# no version-sync tags and no VCS sources, so the run passes no sync flags
# and nothing behavioural is lost.
#
# Lock isolation: the PATH-stub `pacman-conf` answers DBPath with a fixture
# directory, so the host's real /var/lib/pacman/db.lck is never probed. The
# engine reads the installed DB through that answer (never the host's). No
# GSA_* test knob is added — GSA_FAKE_* is consumed by the stubs only.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-shim-fixture.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    printf '%s\n' "$@" >&2
    exit 1
}

# ─── The engine under test: built into the fixture tree (scratch only).
# GSA_TEST_GSA_BIN, when already set to an executable, is that engine (the
# rr-v2.bash run_engine convention) and the scratch build is skipped. ──────
if [ -z "${GSA_TEST_GSA_BIN:-}" ]; then
    cargo build --offline --quiet --target-dir "$fixture/cargo" -p gsa-cli \
        --manifest-path "$gsa_repo_root/Cargo.toml" ||
        fail "cannot build the gsa binary for the fixture"
    GSA_TEST_GSA_BIN="$fixture/cargo/debug/gsa"
fi
[ -x "$GSA_TEST_GSA_BIN" ] || fail "the engine under test is not executable: $GSA_TEST_GSA_BIN"
export GSA_TEST_ENGINE=gsa
export GSA_TEST_GSA_BIN

make_workspace "$fixture" auto auto xhigh
add_package "$fixture" p1 $'pkgver=1.0\npkgrel=1\narch=(x86_64)'
# Dynamic IgnorePkg registration target — never the host's /etc/pacman.conf
# (the battery must be non-mutating). The engine takes it as `--config`.
make_install_conf "$fixture/pacman.conf"

cat >"$fixture/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
name=$(basename "$PWD")
printf '%s\n' "${PACMAN:-}" >>"${GSA_FAKE_PACMAN_ENV_LOG:?fixture forgot GSA_FAKE_PACMAN_ENV_LOG}"
mkdir -p "${GSA_FAKE_MARKER_DIR:?}"
touch "$GSA_FAKE_MARKER_DIR/$name"
sleep "${GSA_FAKE_BUILD_SECONDS:-0.2}"
# REAL archive (staged .PKGINFO tar): the engine's install discovery reads
# each archive's own .PKGINFO, and an empty file refuses `empty-list`.
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
# Password-free host stub: record the call (timestamp|argv — the timestamp
# lets section 2 order the transaction against an external mutex holder),
# never touch a real database.
printf '%s|%s\n' "$(date +%s.%N)" "$*" >>"${GSA_FAKE_SUDO_LOG:?fixture forgot GSA_FAKE_SUDO_LOG}"
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
# The engine shim chains `sudo -n "$P" "$@"` under flock (the fish shim
# called pacman directly): drop the shim's own sudo -n pair so the recorder
# sees the pacman argv VERBATIM, and point the baked pacman at the recorder.
args=()
skip=0
for a in "$@"; do
    if ((skip)); then skip=0; continue; fi
    if [[ $a == sudo ]]; then skip=1; continue; fi
    [[ $a == /usr/bin/pacman ]] && a=$GSA_FAKE_STUB_PACMAN
    args+=("$a")
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
export GSA_STATE_DIR="$state"
export GSA_FAKE_DB_PATH="$state/var/pacman"
export GSA_FAKE_MARKER_DIR="$state/built"
export GSA_FAKE_PACMAN_ENV_LOG="$state/pacman-env.log"
export GSA_FAKE_SUDO_LOG="$state/sudo.log"
export GSA_FAKE_BUILD_SECONDS=1.0
export PATH="$fixture/bin:$PATH"

# Section 2's serialisation probe: hold the engine's transaction mutex from
# outside and let go after a beat. The install must not reach pacman before
# the release — the mutex is the one lock both the shim's dep-pacmans and the
# engine's `pacman -U` serialise on (§K.3).
mutex="$state/locks/pacman-mutex"
release_marker="$fixture/holder-release"
mkdir -p "$state/locks"
(
    flock -x -w 30 "$mutex" -c "sleep 2.0; date +%s.%N >'$release_marker'"
) &
holder=$!

run_engine "$fixture" -S --leaf --config "$fixture/pacman.conf" --lanes 1 --jobs 1 p1
run_output=$FIXTURE_OUTPUT
run_rc=$FIXTURE_RC
wait "$holder" 2>/dev/null

if [[ $run_rc -ne 0 ]]; then
    fail "install-mode run failed (rc=$run_rc)" "$run_output"
fi
rr2_body <<<"$run_output" >/dev/null ||
    fail "no complete format: 2 run record:" "$run_output"
[[ $(rr2_scalar outcome <<<"$run_output") == success ]] ||
    fail "run record outcome is not success:" "$run_output"

# 1. shim generated at run start: mode, mutex wiring, absolute paths.
shim="$state/locks/pacman-shim"
[[ -e $shim ]] ||
    fail "run start did not generate $shim"
[[ $(stat -c %a "$shim") == 755 ]] ||
    fail "shim mode is $(stat -c %a "$shim"), want 755"
grep -q 'flock -x -w 600' "$shim" ||
    fail "shim lacks 'flock -x -w 600': $(cat "$shim")"
grep -qF "$mutex" "$shim" ||
    fail "shim lacks the absolute mutex path $mutex: $(cat "$shim")"
grep -q '/usr/bin/pacman' "$shim" ||
    fail "shim lacks /usr/bin/pacman: $(cat "$shim")"
grep -qF '"$@"' "$shim" ||
    fail "shim does not pass through \"\$@\": $(cat "$shim")"
grep -q 'sudo -n' "$shim" ||
    fail "shim transactions do not run through sudo -n (§K.3): $(cat "$shim")"

# 2. the lane exported PACMAN to makepkg, the install went through the one
#    mutex (it waited for the external holder), and sudo saw `pacman -U`.
grep -qxF "$shim" "$state/pacman-env.log" ||
    fail "stub makepkg did not see PACMAN=$shim:" "$(cat "$state/pacman-env.log")"
grep -q -- '-n pacman -U' "$state/sudo.log" ||
    fail "sudo never saw the lane install:" "$(cat "$state/sudo.log" 2>/dev/null)"
[[ -s $release_marker ]] ||
    fail "the mutex holder never released"
txn_ts=$(grep -- '-n pacman -U' "$state/sudo.log" | head -1 | cut -d'|' -f1)
rel_ts=$(cat "$release_marker")
awk -v txn="$txn_ts" -v rel="$rel_ts" 'BEGIN { exit !(txn + 0 >= rel + 0) }' ||
    fail "the install transaction ran at $txn_ts, before the mutex holder released at $rel_ts:" \
        "$(cat "$state/sudo.log")"

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

# 5. a flock failure is propagated verbatim and runs no pacman; a rc-1
#    failure is named by the shim (DEVIATION 1: the engine names rc 1 only,
#    the fish `builder pacman mutex timed out`/75 mapping has no engine
#    counterpart).
echo "section 5: flock failures propagate and are named (rc 1)"
: >"$qlog"
rc=0
env PATH="$fixture/bin:$PATH" \
    GSA_FAKE_STUB_PACMAN="$fixture/bin/record-pacman" \
    GSA_FAKE_STUB_PACMAN_LOG="$qlog" \
    GSA_FAKE_FLOCK_RC=75 \
    "$qshim" -S --noconfirm pkgname >"$fixture/timeout.out" 2>&1 || rc=$?
[[ $rc -eq 75 ]] ||
    fail "shim timeout rc=$rc, want 75 verbatim" "$(cat "$fixture/timeout.out")"
[[ ! -s $qlog ]] ||
    fail "timeout path still ran pacman: '$(cat "$qlog")'"
: >"$qlog"
rc=0
env PATH="$fixture/bin:$PATH" \
    GSA_FAKE_STUB_PACMAN="$fixture/bin/record-pacman" \
    GSA_FAKE_STUB_PACMAN_LOG="$qlog" \
    GSA_FAKE_FLOCK_RC=1 \
    "$qshim" -S --noconfirm pkgname >"$fixture/fail.out" 2>&1 || rc=$?
[[ $rc -eq 1 ]] ||
    fail "shim failure rc=$rc, want 1" "$(cat "$fixture/fail.out")"
grep -q 'gsa pacman shim: transaction failed' "$fixture/fail.out" ||
    fail "shim does not name the rc-1 transaction failure:" "$(cat "$fixture/fail.out")"
[[ ! -s $qlog ]] ||
    fail "failure path still ran pacman: '$(cat "$qlog")'"

# 6. (FISH-DRIVEN — DEVIATION 2: no engine trigger for `mutex-timeout`) an
#    install that hits the builder mutex wait lands in the run record as a
#    `mutex-timeout` row — not a generic build-failed — the named line
#    reaches the package log, and NO lock/db recovery probe runs on rc 75
#    (the db state seeded mid-run must stay unreported).
echo "section 6: mutex timeout lands as a mutex-timeout run-record row (fish engine)"
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
