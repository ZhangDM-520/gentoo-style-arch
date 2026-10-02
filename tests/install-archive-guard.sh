#!/usr/bin/env bash
set -euo pipefail

# Regression fixture for install archive discovery and its refusal semantics:
#
#  1. list_split_pkgs must use the expanded PKGBUILD value, not assignment text.
#  2. A VCS pkgver() result is the current version after makepkg updates it.
#  3. Unknown version metadata must not broaden discovery to every archive.
#  4. A genuinely missing archive must fail checked install, never report success.
#
# The invariant this fixture enforces is behavioural, not textual: a run that
# reports success under `-i` must have actually installed something. Case B
# pins the second half — when the archive genuinely cannot be found the run
# must FAIL, because silence is what hid the bug for so long.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-install-guard.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

make_case_workspace() { # $1 = sandbox dir, $2 = pkgver line in the PKGBUILD
    local dir=$1 pkgver_line=$2
    make_workspace "$dir" 1 2 low

    # The trailing comment is the whole point of case A: it is legal PKGBUILD
    # syntax and the builder must read the VALUE, not the line. It rides in as
    # add_package's extra-pkglines, so the PKGBUILD stays exactly four lines.
    add_package "$dir" p1 "$pkgver_line"$'\n'"pkgrel=1
arch=(any)"

    cat >"$dir/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
# A real makepkg writes $pkgname-$pkgver-$pkgrel-$arch.pkg.tar.zst into
# $startdir. GSA_FAKE_NO_ARCHIVE models "build succeeded, archive absent".
if [[ "${GSA_FAKE_NO_ARCHIVE:-0}" != 1 ]]; then
    archive=${GSA_FAKE_ARCHIVE_NAME:-p1-1.0.0-1-any.pkg.tar.zst}
    if [[ "${GSA_FAKE_CALL_PKGVER:-0}" == 1 ]]; then
        resolved_pkgver=$(bash -c 'source "$1" >/dev/null 2>&1 && pkgver' _ "$PWD/PKGBUILD")
        [[ -n $resolved_pkgver ]] || exit 1
        sed -i "s/^pkgver=.*/pkgver=$resolved_pkgver/" "$PWD/PKGBUILD"
        archive="p1-$resolved_pkgver-1-any.pkg.tar.zst"
    fi
    : >"$PWD/$archive"
fi
# Invocation counter: the -s cases must observe that a SKIPPED build never
# reaches makepkg — the lane's "already built" line is silent in quiet mode.
if [[ -n ${GSA_FAKE_MAKEPKG_COUNT:-} ]]; then
    printf 'run\n' >>"$GSA_FAKE_MAKEPKG_COUNT"
fi
printf 'fake makepkg %s\n' "$PWD"
exit 0
EOF
    chmod +x "$dir/bin/makepkg"

    # sudo is faked so the fixture never depends on the host's timestamp: the
    # builder's install path is `run_pacman_locked ... sudo pacman -U ...`.
    stub_sudo "$dir"

    # Records every install attempt, so the assertion is "pacman ran with this
    # archive" rather than "the output looked encouraging". The same-version
    # check's queries (-Qp/-Qi) are answered from GSA_FAKE_QP/QI; unset,
    # they print nothing and fail — the builder's conservative
    # "no answer → install" fallback, which is what keeps cases A/B honest.
    cat >"$dir/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'pacman %s\n' "$*" >>"${GSA_FAKE_PACMAN_LOG:?}"
case ${1:-} in
-Qp)
    [[ -n ${GSA_FAKE_QP:-} ]] || exit 1
    printf '%s\n' "$GSA_FAKE_QP"
    ;;
-Qi)
    [[ -n ${GSA_FAKE_QI:-} ]] || exit 1
    printf '%s\n' "$GSA_FAKE_QI"
    ;;
esac
exit "${GSA_FAKE_PACMAN_RC:-0}"
EOF
    chmod +x "$dir/bin/pacman"
}

# Builder flags for the NEXT run_case call; cases override this instead of
# duplicating the fixed --allow-broken-rustc/--no-deps/--no-sync preamble.
builder_args=(-i p1)

# Runs the builder against one sandbox through the helper's capture
# (FIXTURE_OUTPUT/FIXTURE_RC); returns the builder's exit status so the cases'
# `if run_case ...` checks read naturally.
run_case() { # $1 = dir, $2 = extra env NAME=VALUE ...
    local dir=$1
    shift
    run_builder env "$@" \
        PATH="$dir/bin:$PATH" \
        GSA_STATE_DIR="$dir/state" \
        GSA_FAKE_PACMAN_LOG="$dir/pacman.log" \
        GSA_FAKE_MAKEPKG_COUNT="$dir/makepkg.count" \
        GSA_CPU_THREADS=8 \
        GSA_MEMORY_GIB=16 \
        fish "$dir/build-all.fish" \
        --allow-broken-rustc --no-deps --no-sync "${builder_args[@]}"
    return "$FIXTURE_RC"
}

# ─── Case A: trailing comment on pkgver= must not hide the archive ───────────
# Also pins the conservative fallback of the same-version check: the stub
# answers neither -Qp nor -Qi here, and the run must still reach pacman -U.
dir_a="$fixture/case-a"
make_case_workspace "$dir_a" "pkgver=1.0.0 # bump me"
if ! run_case "$dir_a"; then
    printf 'case A: builder failed on a valid PKGBUILD with a commented pkgver:\n%s\n' \
        "$FIXTURE_OUTPUT" >&2
    exit 1
fi
if ! grep -q 'All builds succeeded!' <<<"$FIXTURE_OUTPUT"; then
    printf 'case A: success was not reported at all:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
if [[ ! -s "$dir_a/pacman.log" ]]; then
    printf 'case A: reported success without ever invoking pacman — the archive\n' >&2
    printf 'was not found (trailing comment kept in pkgver) and the empty\n' >&2
    printf 'install was swallowed:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
if ! grep -F 'p1-1.0.0-1-any.pkg.tar.zst' "$dir_a/pacman.log" >/dev/null; then
    printf 'case A: pacman ran without the built archive: %s\n' \
        "$(cat "$dir_a/pacman.log")" >&2
    exit 1
fi

# Case A2: a legal shell expression is metadata, not a filename pattern.
dir_expr="$fixture/case-shell-pkgver"
make_case_workspace "$dir_expr" $'_basever=5.3.15\n_patchlevel=2\npkgver=${_basever}.${_patchlevel}\npkgrel=1\narch=(any)'
if ! run_case "$dir_expr" GSA_FAKE_ARCHIVE_NAME='p1-5.3.15.2-1-any.pkg.tar.zst'; then
    printf 'case A2: builder did not expand a shell-valued pkgver:\n%s\n' \
        "$FIXTURE_OUTPUT" >&2
    exit 1
fi
if ! grep -F 'p1-5.3.15.2-1-any.pkg.tar.zst' "$dir_expr/pacman.log" >/dev/null; then
    printf 'case A2: pacman ran without the archive for the expanded pkgver:\n%s\n' \
        "$(cat "$dir_expr/pacman.log" 2>/dev/null || true)" >&2
    exit 1
fi

# Case A3: makepkg resolves pkgver() during the build and updates the PKGBUILD.
# A stale archive for the pre-build pkgver must not be installed alongside it.
dir_vcs="$fixture/case-vcs-pkgver"
make_case_workspace "$dir_vcs" $'pkgver=1.0.0\npkgrel=1\narch=(any)\npkgver() { echo 2.0.r7.gabc123; }'
: >"$dir_vcs/packages/p1/p1-1.0.0-1-any.pkg.tar.zst"
if ! run_case "$dir_vcs" GSA_FAKE_CALL_PKGVER=1; then
    printf 'case A3: builder did not use the makepkg-resolved VCS pkgver:\n%s\n' \
        "$FIXTURE_OUTPUT" >&2
    exit 1
fi
if ! grep -F 'p1-2.0.r7.gabc123-1-any.pkg.tar.zst' "$dir_vcs/pacman.log" >/dev/null; then
    printf 'case A3: pacman did not receive the post-build pkgver archive:\n%s\n' \
        "$(cat "$dir_vcs/pacman.log" 2>/dev/null || true)" >&2
    exit 1
fi
if grep -F 'p1-1.0.0-1-any.pkg.tar.zst' "$dir_vcs/pacman.log" >/dev/null; then
    printf 'case A3: pacman received a stale pre-build pkgver archive:\n%s\n' \
        "$(cat "$dir_vcs/pacman.log")" >&2
    exit 1
fi

# ─── Case B: no archive at all must FAIL, never report success ───────────────
dir_b="$fixture/case-b"
make_case_workspace "$dir_b" "pkgver=1.0.0"
if run_case "$dir_b" GSA_FAKE_NO_ARCHIVE=1; then
    printf 'case B: `-i` succeeded with no package archive to install:\n%s\n' \
        "$FIXTURE_OUTPUT" >&2
    exit 1
fi
if grep -q 'All builds succeeded!' <<<"$FIXTURE_OUTPUT"; then
    printf 'case B: reported "All builds succeeded!" while failing:\n%s\n' \
        "$FIXTURE_OUTPUT" >&2
    exit 1
fi
if [[ -s "$dir_b/pacman.log" ]]; then
    printf 'case B: pacman ran with nothing to install: %s\n' \
        "$(cat "$dir_b/pacman.log")" >&2
    exit 1
fi

# ─── The same-version sanity check (-i) and its force bypass (-fi) ───────────
# 2026-09-25: the resume idiom -s -i re-ran pacman -U for every already-built
# package even when its exact version was already installed. The builder now
# skips an install only on POSITIVE evidence: version match AND an install
# date not older than the archive (a same-version rebuild still installs).
# Every doubt — no query answer, an unparseable date — must still install.
# -fi implies -i and bypasses the check entirely.

fresh_qi() { # Install Date one day AFTER the archive about to be built
    printf 'Version : %s\nInstall Date : %s\n' "$1" \
        "$(date -d '+1 day' '+%Y-%m-%d %H:%M:%S')"
}

stale_qi() { # Install Date one day BEFORE the archive — same version, old payload
    printf 'Version : %s\nInstall Date : %s\n' "$1" \
        "$(date -d '-1 day' '+%Y-%m-%d %H:%M:%S')"
}

assert_no_u() { # $1 = dir, $2 = label
    if grep -q -- 'pacman -U' "$1/pacman.log" 2>/dev/null; then
        printf '%s: pacman -U ran although the install should have been skipped:\n' "$2" >&2
        cat "$1/pacman.log" >&2
        exit 1
    fi
}

assert_u() { # $1 = dir, $2 = label
    if ! grep -q -- 'pacman -U' "$1/pacman.log" 2>/dev/null; then
        printf '%s: pacman -U never ran:\n' "$2" >&2
        cat "$1/pacman.log" 2>/dev/null >&2 || true
        exit 1
    fi
    if ! grep -F 'p1-1.0.0-1-any.pkg.tar.zst' "$1/pacman.log" >/dev/null; then
        printf '%s: pacman -U ran without the built archive: %s\n' "$2" \
            "$(cat "$1/pacman.log")" >&2
        exit 1
    fi
}

assert_skip_message() { # $1 = dir, $2 = label — quiet lane logs go to state/
    if grep -rq 'already installed' "$1/state" 2>/dev/null ||
        grep -q 'already installed' <<<"$FIXTURE_OUTPUT"; then
        return 0
    fi
    printf '%s: skip-install message missing from log and output:\n%s\n' "$2" \
        "$FIXTURE_OUTPUT" >&2
    exit 1
}

# Case C: exact version already installed, install fresher than the archive
# → no transaction, success still reported.
dir_c="$fixture/case-c"
make_case_workspace "$dir_c" "pkgver=1.0.0"
builder_args=(-i p1)
if ! run_case "$dir_c" GSA_FAKE_QP='p1 1.0.0-1' \
    "GSA_FAKE_QI=$(fresh_qi 1.0.0-1)"; then
    printf 'case C: run failed although the exact version was installed:\n%s\n' \
        "$FIXTURE_OUTPUT" >&2
    exit 1
fi
if ! grep -q 'All builds succeeded!' <<<"$FIXTURE_OUTPUT"; then
    printf 'case C: skip was not reported as success:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
assert_no_u "$dir_c" 'case C'
assert_skip_message "$dir_c" 'case C'

# Case D: a DIFFERENT installed version must install.
dir_d="$fixture/case-d"
make_case_workspace "$dir_d" "pkgver=1.0.0"
builder_args=(-i p1)
if ! run_case "$dir_d" GSA_FAKE_QP='p1 1.0.0-1' \
    "GSA_FAKE_QI=$(fresh_qi 0.9.0-1)"; then
    printf 'case D: run failed on a version difference:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
assert_u "$dir_d" 'case D'

# Case E: same version, but the install PREDATES the archive — a rebuild that
# never reached the system. The freshness guard must install it.
dir_e="$fixture/case-e"
make_case_workspace "$dir_e" "pkgver=1.0.0"
builder_args=(-i p1)
if ! run_case "$dir_e" GSA_FAKE_QP='p1 1.0.0-1' \
    "GSA_FAKE_QI=$(stale_qi 1.0.0-1)"; then
    printf 'case E: run failed on a stale install date:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
assert_u "$dir_e" 'case E'

# Case F: -fi ALONE (no -i) implies install and bypasses the check that
# cases C would apply — same fresh same-version state, but -U must run.
dir_f="$fixture/case-f"
make_case_workspace "$dir_f" "pkgver=1.0.0"
builder_args=(-fi p1)
if ! run_case "$dir_f" GSA_FAKE_QP='p1 1.0.0-1' \
    "GSA_FAKE_QI=$(fresh_qi 1.0.0-1)"; then
    printf 'case F: -fi run failed:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
if ! grep -q 'All builds succeeded!' <<<"$FIXTURE_OUTPUT"; then
    printf 'case F: -fi did not run as an install run:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
if ! grep -q 'Install:  yes (forced)' <<<"$FIXTURE_OUTPUT"; then
    printf 'case F: run summary does not report a forced install:\n%s\n' \
        "$FIXTURE_OUTPUT" >&2
    exit 1
fi
assert_u "$dir_f" 'case F'

# Case G: the original complaint — resume with -s -i: the build is skipped
# AND the already-installed package is not reinstalled.
dir_g="$fixture/case-g"
make_case_workspace "$dir_g" "pkgver=1.0.0"
builder_args=(p1)
if ! run_case "$dir_g"; then # first run: build only (no -i)
    printf 'case G: initial build failed:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
builder_args=(-s -i p1)
if ! run_case "$dir_g" GSA_FAKE_QP='p1 1.0.0-1' \
    "GSA_FAKE_QI=$(fresh_qi 1.0.0-1)"; then
    printf 'case G: -s -i resume failed:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
# makepkg ran exactly ONCE across both runs: run 2 skipped the build. (The
# lane's "already built" ui_info is gated to interactive mode, so the build
# side is observed at the stub, not at the terminal.)
g_runs=$(grep -c '^run$' "$dir_g/makepkg.count" 2>/dev/null || true)
if [[ "$g_runs" != 1 ]]; then
    printf 'case G: -s did not skip the build (makepkg ran %s times):\n%s\n' \
        "$g_runs" "$FIXTURE_OUTPUT" >&2
    exit 1
fi
assert_no_u "$dir_g" 'case G'
assert_skip_message "$dir_g" 'case G'

# Case H: -s -fi — the build is still skipped, but the install is forced.
dir_h="$fixture/case-h"
make_case_workspace "$dir_h" "pkgver=1.0.0"
builder_args=(p1)
if ! run_case "$dir_h"; then # first run: build only (no -i)
    printf 'case H: initial build failed:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
builder_args=(-s -fi p1)
if ! run_case "$dir_h" GSA_FAKE_QP='p1 1.0.0-1' \
    "GSA_FAKE_QI=$(fresh_qi 1.0.0-1)"; then
    printf 'case H: -s -fi resume failed:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
h_runs=$(grep -c '^run$' "$dir_h/makepkg.count" 2>/dev/null || true)
if [[ "$h_runs" != 1 ]]; then
    printf 'case H: -s did not skip the build (makepkg ran %s times):\n%s\n' \
        "$h_runs" "$FIXTURE_OUTPUT" >&2
    exit 1
fi
assert_u "$dir_h" 'case H'

# Case J: no version metadata means no archive is eligible for -ia. The
# unversioned glob-all fallback would let a stale archive bypass the guard.
dir_j="$fixture/case-unknown-version"
make_case_workspace "$dir_j" ""
: >"$dir_j/packages/p1/p1-1.0.0-1-any.pkg.tar.zst"
builder_args=(-ia)
if ! run_case "$dir_j"; then
    printf 'case J: -ia failed instead of treating unknown-version archives as ineligible:\n%s\n' \
        "$FIXTURE_OUTPUT" >&2
    exit 1
fi
if grep -q -- 'pacman -U' "$dir_j/pacman.log" 2>/dev/null; then
    printf 'case J: -ia installed an archive despite missing pkgver/pkgrel:\n%s\n' \
        "$(cat "$dir_j/pacman.log")" >&2
    exit 1
fi
if ! grep -q 'No eligible built packages found' <<<"$FIXTURE_OUTPUT"; then
    printf 'case J: unknown-version archive was not reported as ineligible:\n%s\n' \
        "$FIXTURE_OUTPUT" >&2
    exit 1
fi
builder_args=(-i p1)

# Case K: a PKGBUILD evaluation diagnostic must stay on stderr, not become an
# archive argument through list_split_pkgs' command-substitution caller.
dir_k="$fixture/case-invalid-pkgbuild"
make_case_workspace "$dir_k" $'pkgver=1.0.0\nif then'
: >"$dir_k/packages/p1/p1-1.0.0-1-any.pkg.tar.zst"
builder_args=(-ia)
if ! run_case "$dir_k"; then
    printf 'case K: -ia failed on an invalid recipe instead of rejecting its archive:\n%s\n' \
        "$FIXTURE_OUTPUT" >&2
    exit 1
fi
if grep -q -- 'pacman -U' "$dir_k/pacman.log" 2>/dev/null; then
    printf 'case K: a PKGBUILD evaluation diagnostic reached pacman as an archive:\n%s\n' \
        "$(cat "$dir_k/pacman.log")" >&2
    exit 1
fi
if ! grep -q 'could not evaluate pkgver/pkgrel for archive discovery' <<<"$FIXTURE_OUTPUT"; then
    printf 'case K: PKGBUILD evaluation failure was not reported:\n%s\n' \
        "$FIXTURE_OUTPUT" >&2
    exit 1
fi
builder_args=(-i p1)

# ─── The --install-decide seam: decisions without execution ──────────────────
# 2026-09-26 plan+executor split: install_plan computes the transaction plan
# SILENTLY (install / skip / refuse / noop rows) and install_execute renders
# and runs it. The hidden --install-decide seam prints the plan verbatim
# without executing anything — no pacman -U, no sudo, no makepkg — so a
# fixture can pin decision sets directly. Force mode (-fi/-ia's shared
# pipeline) must NEVER consult the same-version check: its seam run leaves the
# pacman stub entirely untouched (the "one code path, no second
# implementation" pin). Exact-output matching doubles as the silence pin: any
# mid-decision chatter breaks the whole-plan equality.

decide() { # $1 = dir, $2 = mode, $3 = label, rest = archives; env via decide_env
    local dir=$1 mode=$2 label=$3
    shift 3
    : >"$dir/pacman.log"
    rm -f "$dir/sudo.log"
    # Streams split deliberately: the seam's PLAN is stdout and gets an exact
    # match below; fish startup noise (vendor conf.d on a bare function path)
    # lands on stderr where it cannot blur the plan (run_builder's combined
    # capture would).
    DECIDE_RC=0
    env PATH="$dir/bin:$PATH" \
        GSA_FAKE_PACMAN_LOG="$dir/pacman.log" \
        GSA_FAKE_SUDO_LOG="$dir/sudo.log" \
        "${decide_env[@]}" \
        fish "$dir/build-all.fish" --install-decide "$mode" "$@" \
        >"$dir/decide.out" 2>"$dir/decide.err" || DECIDE_RC=$?
    DECIDE_OUT=$(cat "$dir/decide.out")
    if grep -q -- 'pacman -U' "$dir/pacman.log" 2>/dev/null; then
        printf '%s: the seam EXECUTED a transaction:\n%s\n' "$label" \
            "$(cat "$dir/pacman.log")" >&2
        exit 1
    fi
    if [[ -s "$dir/sudo.log" ]]; then
        printf '%s: the seam escalated via sudo:\n%s\n' "$label" \
            "$(cat "$dir/sudo.log")" >&2
        exit 1
    fi
}

decide_assert() { # $1 = label, $2 = want rc, $3 = want full output (one row/line)
    if [[ "$DECIDE_RC" != "$2" || "$DECIDE_OUT" != "$3" ]]; then
        printf '%s: seam rc=%s want=%s; plan mismatch.\nwant: %s\ngot:\n%s\n' \
            "$1" "$DECIDE_RC" "$2" "$3" "$DECIDE_OUT" >&2
        exit 1
    fi
}

dir_i="$fixture/decide"
make_case_workspace "$dir_i" "pkgver=1.0.0"
# A LOGGING sudo stub: the seam must never escalate at all, so even a
# successful sudo call fails the phase.
cat >"$dir_i/bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'sudo %s\n' "$*" >>"${GSA_FAKE_SUDO_LOG:?}"
exit 0
EOF
chmod +x "$dir_i/bin/sudo"
arch="$dir_i/decide-archives/p1-1.0.0-1-any.pkg.tar.zst"
mkdir -p "$(dirname "$arch")"
: >"$arch"

# I1: checked + exact version installed, install fresher than the archive
# → the one positive-evidence skip.
decide_env=(GSA_FAKE_QP='p1 1.0.0-1' "GSA_FAKE_QI=$(fresh_qi 1.0.0-1)")
decide "$dir_i" checked 'decide I1' "$arch"
decide_assert 'decide I1 (checked, fresh install)' 0 "skip $arch 1.0.0-1"

# I2: version mismatch → install (doubt installs).
decide_env=(GSA_FAKE_QP='p1 1.0.0-1' "GSA_FAKE_QI=$(fresh_qi 0.9.0-1)")
decide "$dir_i" checked 'decide I2' "$arch"
decide_assert 'decide I2 (checked, version mismatch)' 0 "install $arch"

# I3: same version but install date older than the archive (a same-version
# rebuild) → install.
decide_env=(GSA_FAKE_QP='p1 1.0.0-1' "GSA_FAKE_QI=$(stale_qi 1.0.0-1)")
decide "$dir_i" checked 'decide I3' "$arch"
decide_assert 'decide I3 (checked, stale install date)' 0 "install $arch"

# I4: neither query answers (doubt) → install.
decide_env=()
decide "$dir_i" checked 'decide I4' "$arch"
decide_assert 'decide I4 (checked, no query answers)' 0 "install $arch"

# I5: force mode over a perfectly fresh install → install anyway, and the
# pacman stub is never consulted at all: force bypasses install_skip_reason
# entirely (-ia shares this path; no second implementation).
decide_env=(GSA_FAKE_QP='p1 1.0.0-1' "GSA_FAKE_QI=$(fresh_qi 1.0.0-1)")
decide "$dir_i" force 'decide I5' "$arch"
decide_assert 'decide I5 (force bypasses the skip check)' 0 "install $arch"
if [[ -s "$dir_i/pacman.log" ]]; then
    printf 'decide I5: force mode consulted the installed database:\n%s\n' \
        "$(cat "$dir_i/pacman.log")" >&2
    exit 1
fi

# I6: checked + nothing to install → refusal (the 2026-09-20 silence bug).
decide_env=()
decide "$dir_i" checked 'decide I6'
decide_assert 'decide I6 (checked, empty list)' 1 'refuse empty-list'

# I7: force + nothing to install → a no-op plan, not a refusal (-ia on a
# workspace with nothing built is a no-op success).
decide "$dir_i" force 'decide I7'
decide_assert 'decide I7 (force, empty list)' 0 'noop empty-list'

printf 'install archive guard fixture: PASS\n'
