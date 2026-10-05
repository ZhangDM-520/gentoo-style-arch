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

# planrow FIELD... — the plan-row codec's framing (tab-separated fields, the
# 2026-10-05 R-F22 grammar): fixture expectations must frame rows exactly as
# install_plan prints them, spaces inside fields and all.
planrow() {
    local IFS=$'\t'
    printf '%s' "$*"
}

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
decide_assert 'decide I1 (checked, fresh install)' 0 "$(planrow skip "$arch" 1.0.0-1)"

# I2: version mismatch → install (doubt installs).
decide_env=(GSA_FAKE_QP='p1 1.0.0-1' "GSA_FAKE_QI=$(fresh_qi 0.9.0-1)")
decide "$dir_i" checked 'decide I2' "$arch"
decide_assert 'decide I2 (checked, version mismatch)' 0 "$(planrow install "$arch")"

# I3: same version but install date older than the archive (a same-version
# rebuild) → install.
decide_env=(GSA_FAKE_QP='p1 1.0.0-1' "GSA_FAKE_QI=$(stale_qi 1.0.0-1)")
decide "$dir_i" checked 'decide I3' "$arch"
decide_assert 'decide I3 (checked, stale install date)' 0 "$(planrow install "$arch")"

# I4: neither query answers (doubt) → install.
decide_env=()
decide "$dir_i" checked 'decide I4' "$arch"
decide_assert 'decide I4 (checked, no query answers)' 0 "$(planrow install "$arch")"

# I5: force mode over a perfectly fresh install → install anyway, and the
# pacman stub is never consulted at all: force bypasses install_skip_reason
# entirely (-ia shares this path; no second implementation).
decide_env=(GSA_FAKE_QP='p1 1.0.0-1' "GSA_FAKE_QI=$(fresh_qi 1.0.0-1)")
decide "$dir_i" force 'decide I5' "$arch"
decide_assert 'decide I5 (force bypasses the skip check)' 0 "$(planrow install "$arch")"
if [[ -s "$dir_i/pacman.log" ]]; then
    printf 'decide I5: force mode consulted the installed database:\n%s\n' \
        "$(cat "$dir_i/pacman.log")" >&2
    exit 1
fi

# I6: checked + nothing to install → refusal (the 2026-09-20 silence bug).
decide_env=()
decide "$dir_i" checked 'decide I6'
decide_assert 'decide I6 (checked, empty list)' 1 "$(planrow refuse empty-list)"

# I7: force + nothing to install → a no-op plan, not a refusal (-ia on a
# workspace with nothing built is a no-op success).
decide "$dir_i" force 'decide I7'
decide_assert 'decide I7 (force, empty list)' 0 "$(planrow noop empty-list)"

# ─── Split-output set completeness at install discovery (R-F2) ───────────────
# Installing a SUBSET of a split recipe's outputs is a silent wrong claim: the
# outputs are discovered as a set and a partial set is excluded with a named
# warning, never half-installed. The expected set comes from the committed
# .SRCINFO here (skip-upstream.sh pins the evaluated-pkgname fallback), and
# GSA_FAKE_DROP_OUTPUT models a build that died between the two outputs.

make_split_workspace() { # $1 = dir — .SRCINFO-backed two-output recipe
    make_case_workspace "$1" "pkgver=1.0.0"
    printf '%s\n' 'pkgname=(p1 p1-extra)' 'pkgver=1.0.0' 'pkgrel=1' 'arch=(any)' \
        >"$1/packages/p1/PKGBUILD"
    printf '%s\n' 'pkgbase = p1' 'pkgname = p1' 'pkgname = p1-extra' \
        'pkgver = 1.0.0' 'pkgrel = 1' 'arch = any' >"$1/packages/p1/.SRCINFO"
    cat >"$1/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
: >"$PWD/p1-1.0.0-1-any.pkg.tar.zst"
if [[ "${GSA_FAKE_DROP_OUTPUT:-0}" != 1 ]]; then
    : >"$PWD/p1-extra-1.0.0-1-any.pkg.tar.zst"
fi
if [[ -n ${GSA_FAKE_MAKEPKG_COUNT:-} ]]; then
    printf 'run\n' >>"$GSA_FAKE_MAKEPKG_COUNT"
fi
printf 'fake makepkg %s\n' "$PWD"
exit 0
EOF
    chmod +x "$1/bin/makepkg"
}

# S1: a complete set installs every output in the one transaction.
dir_s1="$fixture/split-complete"
make_split_workspace "$dir_s1"
builder_args=(-i p1)
if ! run_case "$dir_s1"; then
    printf 'case S1: -i failed on a complete split set:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
for out in p1-1.0.0-1-any.pkg.tar.zst p1-extra-1.0.0-1-any.pkg.tar.zst; do
    if ! grep -- 'pacman -U' "$dir_s1/pacman.log" 2>/dev/null | grep -Fq "$out"; then
        printf 'case S1: pacman -U did not receive %s:\n%s\n' "$out" \
            "$(cat "$dir_s1/pacman.log" 2>/dev/null || true)" >&2
        exit 1
    fi
done

# S2: a PARTIAL set must fail checked install: nothing is installed (not even
# the surviving output) and the missing output is named.
dir_s2="$fixture/split-partial"
make_split_workspace "$dir_s2"
builder_args=(-i p1)
if run_case "$dir_s2" GSA_FAKE_DROP_OUTPUT=1; then
    printf 'case S2: -i succeeded while half the split set is missing:\n%s\n' \
        "$FIXTURE_OUTPUT" >&2
    exit 1
fi
assert_no_u "$dir_s2" 'case S2'
if ! grep -Fq 'is incomplete' <<<"$FIXTURE_OUTPUT" ||
    ! grep -Fq 'p1-extra' <<<"$FIXTURE_OUTPUT"; then
    printf 'case S2: the partial set was not reported by name:\n%s\n' \
        "$FIXTURE_OUTPUT" >&2
    exit 1
fi

# S3: -ia is the force/no-op escape hatch — a partial set is excluded from its
# discovery the same way (warning names the missing output), but an empty
# force plan is a no-op success, never a transaction and never a refusal.
dir_s3="$fixture/split-installall"
make_split_workspace "$dir_s3"
: >"$dir_s3/packages/p1/p1-1.0.0-1-any.pkg.tar.zst"
builder_args=(-ia)
if ! run_case "$dir_s3"; then
    printf 'case S3: -ia failed on a partial split set (force empty is a no-op):\n%s\n' \
        "$FIXTURE_OUTPUT" >&2
    exit 1
fi
assert_no_u "$dir_s3" 'case S3'
if ! grep -Fq 'No eligible built packages found' <<<"$FIXTURE_OUTPUT"; then
    printf 'case S3: the partial set was not excluded from -ia discovery:\n%s\n' \
        "$FIXTURE_OUTPUT" >&2
    exit 1
fi
if ! grep -Fq 'is incomplete' <<<"$FIXTURE_OUTPUT" ||
    ! grep -Fq 'p1-extra' <<<"$FIXTURE_OUTPUT"; then
    printf 'case S3: the exclusion did not name the missing output:\n%s\n' \
        "$FIXTURE_OUTPUT" >&2
    exit 1
fi

# ─── R-F37: the freshness compare is NANOSECOND, not second ─────────────────
# The install date is second-granular, so a second-equality compare skipped a
# same-version rebuild whose archive was written mid-second AFTER the install
# instant. Doubt installs: an archive newer by nanoseconds must install; an
# install genuinely at-or-after the archive still skips.
(
    dir_f37="$fixture/decide-f37"
    make_case_workspace "$dir_f37" "pkgver=1.0.0"
    arch_f="$dir_f37/decide-archives/p1-1.0.0-1-any.pkg.tar.zst"
    mkdir -p "$(dirname "$arch_f")"
    : >"$arch_f"
    qi_at() { # $1 = version, $2 = install epoch (second granularity)
        printf 'Version : %s\nInstall Date : %s\n' "$1" \
            "$(date -d "@$2" '+%Y-%m-%d %H:%M:%S')"
    }

    # Same second, archive half a second AFTER the install instant → install.
    # The old second-equality compare reported this as fresh and skipped it.
    touch -d '@1700000000.5' "$arch_f"
    decide_env=(GSA_FAKE_QP='p1 1.0.0-1' "GSA_FAKE_QI=$(qi_at 1.0.0-1 1700000000)")
    decide "$dir_f37" checked 'decide F37-same-second' "$arch_f"
    decide_assert 'F37: ns-newer archive inside the install second must install' 0 "$(planrow install "$arch_f")"

    # Archive exactly at the install instant → the one equality that skips.
    touch -d '@1700000000' "$arch_f"
    decide "$dir_f37" checked 'decide F37-exact' "$arch_f"
    decide_assert 'F37: an archive at the install instant still skips' 0 "$(planrow skip "$arch_f" 1.0.0-1)"

    # Archive a second earlier (ns before the install) → still skips.
    touch -d '@1699999999.5' "$arch_f"
    decide_env=(GSA_FAKE_QP='p1 1.0.0-1' "GSA_FAKE_QI=$(qi_at 1.0.0-1 1700000000)")
    decide "$dir_f37" checked 'decide F37-older' "$arch_f"
    decide_assert 'F37: an older archive with a fresher install still skips' 0 "$(planrow skip "$arch_f" 1.0.0-1)"
)

# ─── R-F22 (decision half): a spaced archive path survives the row codec ────
(
    dir_sp="$fixture/decide-space"
    make_case_workspace "$dir_sp" "pkgver=1.0.0"
    arch_sp="$dir_sp/decide archives/p1 with space-1.0.0-1-any.pkg.tar.zst"
    mkdir -p "$(dirname "$arch_sp")"
    : >"$arch_sp"
    decide_env=()
    decide "$dir_sp" checked 'decide space-install' "$arch_sp"
    decide_assert 'R-F22: the install row keeps a spaced path intact' 0 "$(planrow install "$arch_sp")"
    decide_env=(GSA_FAKE_QP='p1 1.0.0-1' "GSA_FAKE_QI=$(fresh_qi 1.0.0-1)")
    decide "$dir_sp" checked 'decide space-skip' "$arch_sp"
    decide_assert 'R-F22: the skip row keeps a spaced path intact' 0 "$(planrow skip "$arch_sp" 1.0.0-1)"
)

# ─── R-F25: -ia must not silently install a shrunken set ────────────────────
# One recipe's discovery is damaged (pkgver evaluation fails) while another
# has a complete built set. "Install everything" may not install the
# evaluable subset and report success — the plan refuses the omission by name.
(
    dir_r25="$fixture/ia-shrink"
    make_case_workspace "$dir_r25" "pkgver=1.0.0"
    add_package "$dir_r25" p2 $'if then'
    : >"$dir_r25/packages/p1/p1-1.0.0-1-any.pkg.tar.zst"
    : >"$dir_r25/packages/p2/p2-1.0.0-1-any.pkg.tar.zst"
    builder_args=(-ia)
    if run_case "$dir_r25"; then
        printf 'R-F25: -ia installed the evaluable subset although p2 discovery failed:\n%s\n' \
            "$FIXTURE_OUTPUT" >&2
        exit 1
    fi
    grep -Fq 'archive discovery could not be established' <<<"$FIXTURE_OUTPUT" ||
        { printf 'R-F25: the refusal does not name the discovery failure:\n%s\n' "$FIXTURE_OUTPUT" >&2; exit 1; }
    grep -Fq 'p2' <<<"$FIXTURE_OUTPUT" ||
        { printf 'R-F25: the refusal does not name p2:\n%s\n' "$FIXTURE_OUTPUT" >&2; exit 1; }
    if grep -q -- 'pacman -U' "$dir_r25/pacman.log" 2>/dev/null; then
        printf 'R-F25: a transaction ran over the shrunken set:\n%s\n' "$(cat "$dir_r25/pacman.log")" >&2
        exit 1
    fi
    if grep -q 'No eligible built packages found' <<<"$FIXTURE_OUTPUT"; then
        printf 'R-F25: a non-empty set reported as nothing-eligible:\n%s\n' "$FIXTURE_OUTPUT" >&2
        exit 1
    fi
)

# ─── Wave-1 follow-up: a partial set refuses with the named refusal row ─────
# The discovery layer already excludes the partial set; the plan must surface
# the refusal as its own rendered row (`refuse partial-set`), not fall
# through to the misleading `refuse empty-list`.
(
    dir_ps="$fixture/partial-refusal"
    make_split_workspace "$dir_ps"
    builder_args=(-i p1)
    if run_case "$dir_ps" GSA_FAKE_DROP_OUTPUT=1; then
        printf 'partial-set: -i succeeded over a partial set:\n%s\n' "$FIXTURE_OUTPUT" >&2
        exit 1
    fi
    if ! grep -rq 'refusing to install' "$dir_ps/state" 2>/dev/null &&
        ! grep -q 'refusing to install' <<<"$FIXTURE_OUTPUT"; then
        printf 'partial-set: no named refusal row was rendered:\n%s\n' "$FIXTURE_OUTPUT" >&2
        exit 1
    fi
    grep -Fq 'is incomplete' <<<"$FIXTURE_OUTPUT" ||
        { printf 'partial-set: the refusal lost the incomplete-set reason:\n%s\n' "$FIXTURE_OUTPUT" >&2; exit 1; }
    grep -Fq 'p1-extra' <<<"$FIXTURE_OUTPUT" ||
        { printf 'partial-set: the refusal lost the missing output name:\n%s\n' "$FIXTURE_OUTPUT" >&2; exit 1; }
    assert_no_u "$dir_ps" 'partial-set'
)

# ─── D-F13: the empty-list refusal renders through install_emit ────────────
# One message text, one rendering seam — the checked empty-set refusal lands
# in the lane transcript (quiet sink) with exactly the unified wording.
(
    dir_e13="$fixture/empty-list-render"
    make_case_workspace "$dir_e13" "pkgver=1.0.0"
    builder_args=(-i p1)
    if run_case "$dir_e13" GSA_FAKE_NO_ARCHIVE=1; then
        printf 'D-F13: -i succeeded with nothing to install:\n%s\n' "$FIXTURE_OUTPUT" >&2
        exit 1
    fi
    if ! grep -rqF 'install requested but no built package archive matched the current pkgver-pkgrel — refusing to report success' "$dir_e13/state" 2>/dev/null &&
        ! grep -qF 'install requested but no built package archive matched the current pkgver-pkgrel — refusing to report success' <<<"$FIXTURE_OUTPUT"; then
        printf 'D-F13: the empty-list refusal did not render through install_emit:\n%s\n' "$FIXTURE_OUTPUT" >&2
        exit 1
    fi
)

# ─── D-F14: a mixed skip note shows every version, not one row's ────────────
# Two skipped outputs with DIFFERENT installed versions in one transaction:
# the note must present the version set. The old note printed the last row's
# version for both packages.
(
    dir_e14="$fixture/multi-skip-note"
    make_split_workspace "$dir_e14"
    cat >"$dir_e14/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'pacman %s\n' "$*" >>"${GSA_FAKE_PACMAN_LOG:?}"
last=''
for a in "$@"; do last=$a; done
base=${last##*/}
case ${1:-} in
-Qp)
    case "$base" in
    p1-extra-*) printf 'p1-extra 2.0-1\n' ;;
    p1-*) printf 'p1 1.0.0-1\n' ;;
    *) exit 1 ;;
    esac
    ;;
-Qi)
    case "$last" in
    p1)
        printf 'Version : 1.0.0-1\nInstall Date : %s\n' "$(date -d '+1 day' '+%Y-%m-%d %H:%M:%S')"
        ;;
    p1-extra)
        printf 'Version : 2.0-1\nInstall Date : %s\n' "$(date -d '+1 day' '+%Y-%m-%d %H:%M:%S')"
        ;;
    *) exit 1 ;;
    esac
    ;;
esac
exit 0
EOF
    chmod +x "$dir_e14/bin/pacman"
    builder_args=(-i p1)
    if ! run_case "$dir_e14"; then
        printf 'D-F14: -i failed on a fully-skipped split set:\n%s\n' "$FIXTURE_OUTPUT" >&2
        exit 1
    fi
    skip_note=$(grep -rh 'skipping their install' "$dir_e14/state" 2>/dev/null || true)
    [[ -n $skip_note ]] || skip_note=$(grep 'skipping their install' <<<"$FIXTURE_OUTPUT" || true)
    if [[ "$skip_note" != *'1.0.0-1'* || "$skip_note" != *'2.0-1'* ]]; then
        printf 'D-F14: the skip note lost a version:\nnote: %s\nrun:\n%s\n' \
            "$skip_note" "$FIXTURE_OUTPUT" >&2
        exit 1
    fi
    if grep -q -- 'pacman -U' "$dir_e14/pacman.log" 2>/dev/null; then
        printf 'D-F14: both outputs were already installed but pacman -U ran:\n%s\n' \
            "$(cat "$dir_e14/pacman.log")" >&2
        exit 1
    fi
)

printf 'install archive guard fixture: PASS\n'
