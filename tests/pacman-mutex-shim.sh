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

chmod +x "$fixture/bin/"*

state="$fixture/state"
mkdir -p "$state"
run_rc=0
run_output=$(
    env PATH="$fixture/bin:$PATH" \
        GSA_STATE_DIR="$state" \
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
[[ $(cat "$stub_log") == '-S --noconfirm arg with space wild*card' ]] ||
    fail "shim did not pass \$@ through verbatim: '$(cat "$stub_log")'"

if ps -eo args= | grep -F "$fixture" | grep -v grep >/dev/null; then
    fail "a fixture process survived:" \
        "$(ps -eo args= | grep -F "$fixture" | grep -v grep)"
fi

printf 'pacman-mutex-shim fixture: PASS\n'
