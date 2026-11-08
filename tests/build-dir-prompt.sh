#!/usr/bin/env bash
set -euo pipefail

# Build-cache root prompt fixture (contract §J.2/§B.8): a build-shaped run
# asks which root makepkg's BUILDDIR/PKGDIR/PKGDEST live under unless
# something already answered the question.
#
# Pins (one behaviour per section):
#   A. no prompt off a TTY, and the record carries no --build-dir   [non-TTY]
#   B. Enter on a TTY keeps the resolved root, which is shown WITH its
#      provenance (gsa.conf build_dir)                              [PTY ⏎]
#   C. a typed path becomes the run's root and mirrors into the
#      continuation, so a resume rebuilds into the same tree        [PTY path]
#   D. --no-build-dir-prompt restores the silent pre-prompt behaviour
#      (no input is supplied, so a prompt would abort)              [flag]
#   E. --build-dir answers it silently and mirrors                 [flag]
#   F. GSA_BUILD_DIR answers it silently (an explicit environment
#      override is an answer, not a default); its leaves the
#      continuation as an env-required entry, never a flag         [env]
#   G. a built-in-default root is reported when no layer set one    [PTY ⏎]
#   H. q aborts (rc 2, one named line) and a relative --build-dir is a
#      usage error naming the flag                                [refusals]
#   I. a non-build spelling refuses --build-dir as deferred         [gate]
#
# The engine is invoked directly (not through rr2_engine_argv) ON PURPOSE:
# that helper exports GSA_BUILD_DIR whenever the caller did not pin one, which
# is exactly the silent answer these sections must be able to omit.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-builddir.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    printf 'build-dir-prompt: %s\n' "$1" >&2
    if [ -n "${2:-}" ] && [ -f "$2" ]; then
        sed 's/^/    /' "$2" >&2
    fi
    exit 1
}

gsa_bin=${GSA_TEST_GSA_BIN:-$(command -v gsa || true)}
[[ -x ${gsa_bin:-} ]] || fail "engine under test is not executable: ${GSA_TEST_GSA_BIN:-gsa}"
gsa_bin=$(readlink -f "$gsa_bin")

ws=$fixture/ws
make_workspace "$ws" 1 1 low
add_package "$ws" p1 "$gsa_meta_any" git
mkdir -p "$fixture/home" "$fixture/tmp" "$fixture/conf-build"

# The config layer names a build_dir so the prompt's provenance is pinned;
# `basic` (no build_dir) drives the built-in-default section.
printf 'build_dir = %s\n' "$fixture/conf-build" >"$fixture/gsa.conf"
printf '# no build_dir key\n' >"$fixture/gsa-nokey.conf"

# run_dir CONF OUT INPUT [ARG...] — one build-shaped run. GSA_BUILD_DIR is
# stripped by default (an answer is what these sections vary); RUN_ENV carries
# the deliberate exceptions. stdin is the printf-format INPUT, so an empty
# answer and a closed stream stay distinct.
RUN_ENV=()
run_dir() {
    local conf=$1 out=$2 input=$3
    shift 3
    local runner=$fixture/runner.sh
    local -a renv=(-u GSA_BUILD_DIR
        "HOME=$fixture/home" "TMPDIR=$fixture/tmp" "GSA_CONF=$conf"
        "GSA_STATE_DIR=$fixture/state" "GSA_RECIPES_DIR=$fixture/recipes")
    if ((${#RUN_ENV[@]})); then
        renv+=("${RUN_ENV[@]}")
    fi
    {
        printf '#!/bin/bash\n'
        printf 'cd %q || exit 127\n' "$ws"
        printf 'exec env'
        printf ' %q' "${renv[@]}"
        printf ' %q' "$gsa_bin"
        printf ' %q' "$@"
        printf '\n'
    } >"$runner"
    # set -e stays off until the caller decides: returning non-zero with it
    # on would kill the fixture instead of reaching its `|| fail`.
    set +e
    printf '%b' "$input" |
        timeout 60 env TERM=dumb script -qec "/bin/bash $(printf %q "$runner")" /dev/null \
            >"$out" 2>&1
    RC=$?
    ((RC == 0)) && set -e
    return "$RC"
}

# run_pipe OUT [ARG...] — the non-TTY twin (stdin closed, stdout a pipe).
run_pipe() {
    local out=$1
    shift
    set +e
    (
        cd "$ws" &&
            env -u GSA_BUILD_DIR HOME="$fixture/home" TMPDIR="$fixture/tmp" \
                GSA_CONF="$fixture/gsa.conf" GSA_STATE_DIR="$fixture/state" \
                GSA_RECIPES_DIR="$fixture/recipes" \
                "$gsa_bin" "$@"
    ) >"$out" 2>&1 </dev/null
    RC=$?
    ((RC == 0)) && set -e
    return "$RC"
}

# assert_no_prompt OUT — the menu is absent.
assert_no_prompt() {
    if grep -q 'build directory (makepkg' "$1"; then
        fail "the run prompted when it should have stayed silent" "$1"
    fi
}

# assert_prompt OUT — the menu is present and names the current root.
assert_prompt() {
    grep -q 'build directory (makepkg' "$1" || fail "the run did not prompt" "$1"
    grep -q 'build dir> ' "$1" || fail "the prompt rendered no input line" "$1"
}

# continuation_command OUT — the record's `command:` line (CR-stripped body).
continuation_command() {
    rr2_continuation command <"$1"
}

# ── A. no TTY, no answer: silent, and nothing in the record ────────────────
run_pipe "$fixture/a.out" -B --dry-run --leaf p1 || fail "non-TTY plan failed (rc=$RC)" "$fixture/a.out"
assert_no_prompt "$fixture/a.out"
rr2_body <"$fixture/a.out" >/dev/null || fail "the plan emitted no format: 2 record" "$fixture/a.out"
if continuation_command "$fixture/a.out" | grep -q -- '--build-dir'; then
    fail "a non-TTY run invented a --build-dir in its continuation" "$fixture/a.out"
fi

# ── B. Enter keeps the resolved root and shows where it came from ──────────
run_dir "$fixture/gsa.conf" "$fixture/b.out" '\n' -B --dry-run --leaf p1 \
    || fail "Enter-answer plan failed (rc=$RC)" "$fixture/b.out"
assert_prompt "$fixture/b.out"
grep -qF "current: $fixture/conf-build  [gsa.conf build_dir]" "$fixture/b.out" \
    || fail "the prompt did not name the current root and its provenance" "$fixture/b.out"
if continuation_command "$fixture/b.out" | grep -q -- '--build-dir'; then
    fail "accepting the default still recorded a --build-dir" "$fixture/b.out"
fi

# ── C. a typed path is this run's root and mirrors ────────────────────────
chosen=$fixture/chosen-build
run_dir "$fixture/gsa.conf" "$fixture/c.out" "$chosen\n" -B --dry-run --leaf p1 \
    || fail "typed-path plan failed (rc=$RC)" "$fixture/c.out"
assert_prompt "$fixture/c.out"
continuation_command "$fixture/c.out" | grep -qF -- "--build-dir $chosen" \
    || fail "the continuation does not restate the chosen root" "$fixture/c.out"

# ── D. --no-build-dir-prompt: silent, and EOF proves no read happened ──────
run_dir "$fixture/gsa.conf" "$fixture/d.out" '' -B --dry-run --leaf p1 --no-build-dir-prompt \
    || fail "--no-build-dir-prompt run failed (rc=$RC; a prompt would abort on EOF)" "$fixture/d.out"
assert_no_prompt "$fixture/d.out"
continuation_command "$fixture/d.out" | grep -qF -- '--no-build-dir-prompt' \
    || fail "the continuation dropped --no-build-dir-prompt" "$fixture/d.out"

# ── E. --build-dir answers silently and mirrors ───────────────────────────
flagdir=$fixture/flag-build
run_dir "$fixture/gsa.conf" "$fixture/e.out" '' -B --dry-run --leaf p1 --build-dir "$flagdir" \
    || fail "--build-dir run failed (rc=$RC)" "$fixture/e.out"
assert_no_prompt "$fixture/e.out"
continuation_command "$fixture/e.out" | grep -qF -- "--build-dir $flagdir" \
    || fail "the continuation does not restate --build-dir" "$fixture/e.out"

# ── F. GSA_BUILD_DIR is an answer: silent, env-required, never a flag ─────
envdir=$fixture/env-build
RUN_ENV=("GSA_BUILD_DIR=$envdir")
run_dir "$fixture/gsa.conf" "$fixture/f.out" '' -B --dry-run --leaf p1 \
    || fail "GSA_BUILD_DIR run failed (rc=$RC)" "$fixture/f.out"
RUN_ENV=()
assert_no_prompt "$fixture/f.out"
if continuation_command "$fixture/f.out" | grep -q -- '--build-dir'; then
    fail "an environment answer became a --build-dir flag" "$fixture/f.out"
fi
rr2_continuation env-required <"$fixture/f.out" | grep -q 'GSA_BUILD_DIR' \
    || fail "the environment answer is not warned about in env-required" "$fixture/f.out"

# ── G. no config key: the built-in default is reported ────────────────────
run_dir "$fixture/gsa-nokey.conf" "$fixture/g.out" '\n' -B --dry-run --leaf p1 \
    || fail "built-in-default plan failed (rc=$RC)" "$fixture/g.out"
grep -qF "current: $fixture/home/.cache/gsa  [the built-in default]" "$fixture/g.out" \
    || fail "the prompt did not report the built-in default" "$fixture/g.out"

# ── H. refusals ───────────────────────────────────────────────────────────
set +e
run_dir "$fixture/gsa.conf" "$fixture/h1.out" 'q\n' -B --dry-run --leaf p1
rc_abort=$RC
set -e
[ "$rc_abort" = 2 ] || fail "q did not abort with rc 2 (rc=$rc_abort)" "$fixture/h1.out"
grep -q 'build-dir selection aborted' "$fixture/h1.out" \
    || fail "q printed no abort line" "$fixture/h1.out"

run_pipe "$fixture/h2.out" -B --dry-run --leaf p1 --build-dir relative/tree
[ "$RC" = 2 ] || fail "a relative --build-dir was not a usage error (rc=$RC)" "$fixture/h2.out"
grep -q -- '--build-dir' "$fixture/h2.out" \
    || fail "the relative --build-dir refusal does not name the flag" "$fixture/h2.out"

# ── I. a read-only family refuses the build-run flag ──────────────────────
run_pipe "$fixture/i.out" -Q --build-dir /tmp/x
[ "$RC" = 2 ] || fail "-Q accepted a build-only flag (rc=$RC)" "$fixture/i.out"
grep -q 'deferred to a later phase' "$fixture/i.out" \
    || fail "-Q did not refuse --build-dir through the deferred vocabulary" "$fixture/i.out"
