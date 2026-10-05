#!/usr/bin/env bash
set -euo pipefail

# The failure summary prints a copy-pasteable resume command. It used to carry
# only --lanes/--jobs/--intensity, so a resume of a run made with -i rebuilt the
# remaining packages WITHOUT installing them — while the tip printed directly
# below it said "add -s so already-built pkgs are skipped", and the code's own
# comment says to resume with "-s -i". Later packages then compile against the
# old installed ABIs, which is the rule-11 hazard -i exists to prevent.
#
# This fixture fails a middle package so a remainder exists, and requires the
# resume command to preserve the flags that change what the resume means.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-resume-cmd.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

# Three independent packages: p2 fails, so p3 is never dispatched and the
# summary has something to resume. Stubs come from the helper: trivial makepkg
# (fail on GSA_FAKE_FAIL_PACKAGE + touch archive), sudo passthrough, pacman log.
make_case_workspace() { # $1 = sandbox dir
    local dir=$1 id
    make_workspace "$dir" 1 2 low
    # Dynamic IgnorePkg registration target — per-case, never the host's
    # /etc/pacman.conf (the battery must be non-mutating).
    make_install_conf "$dir/pacman.conf"
    for id in p1 p2 p3; do
        add_package "$dir" "$id" $'pkgver=1.0.0\npkgrel=1\narch=(any)'
    done
    stub_makepkg "$dir"
    stub_sudo "$dir"
    stub_pacman "$dir"
}

# run_expecting_failure <dir> <label> [builder flags...] -> RESUME_OUTPUT
run_expecting_failure() {
    local dir=$1 label=$2
    shift 2
    set +e
    RESUME_OUTPUT=$(
        PATH="$dir/bin:$PATH" \
            GSA_STATE_DIR="$dir/state" \
            _IGNOREPKG_CONF="$dir/pacman.conf" \
            GSA_FAKE_PACMAN_LOG="$dir/pacman.log" \
            GSA_FAKE_FAIL_PACKAGE=p2 \
            GSA_CPU_THREADS=8 \
            GSA_MEMORY_GIB=16 \
            fish "$dir/build-all.fish" "$@" p1 p2 p3 2>&1
    )
    local rc=$?
    set -e
    if ((rc == 0)); then
        printf '%s: the failing run unexpectedly succeeded:\n%s\n' "$label" "$RESUME_OUTPUT" >&2
        exit 1
    fi
    if ! grep -q '^  build-all.fish ' <<<"$RESUME_OUTPUT"; then
        printf '%s: no resume command in the failure summary:\n%s\n' "$label" "$RESUME_OUTPUT" >&2
        exit 1
    fi
    RESUME_CMD=$(grep '^  build-all.fish ' <<<"$RESUME_OUTPUT" | head -1)
    # The machine block is the outcome interface: every failing run records
    # `outcome: failed`, and the suggestion must list exactly the record's
    # non-succeeded rows, in row order — one owner for what remains.
    if [[ $(rr_scalar outcome <<<"$RESUME_OUTPUT") != failed ]]; then
        printf '%s: run record outcome is %s, want failed:\n%s\n' \
            "$label" "$(rr_scalar outcome <<<"$RESUME_OUTPUT")" "$RESUME_OUTPUT" >&2
        exit 1
    fi
    RESUME_SET=$(rr_remaining <<<"$RESUME_OUTPUT" | tr '\n' ' ')
    RESUME_SET=${RESUME_SET% }
    if [[ "$RESUME_CMD" != *" $RESUME_SET" ]]; then
        printf '%s: resume command does not end with the run-record resume set [%s]:\n  %s\n' \
            "$label" "$RESUME_SET" "$RESUME_CMD" >&2
        exit 1
    fi
}

# ─── A -i run must resume with --install, or it silently stops installing ────
dir="$fixture/with-install"
make_case_workspace "$dir"
run_expecting_failure "$dir" 'with -i' --install --no-deps --allow-broken-rustc --no-sync
for flag in --install --no-deps --allow-broken-rustc --no-sync; do
    if [[ "$RESUME_CMD" != *"$flag"* ]]; then
        printf 'with -i: resume command dropped %s:\n  %s\n' "$flag" "$RESUME_CMD" >&2
        exit 1
    fi
done
if [[ "$RESUME_CMD" != *"p3"* ]]; then
    printf 'with -i: resume command does not name the unbuilt package:\n  %s\n' \
        "$RESUME_CMD" >&2
    exit 1
fi

# ─── A -fi run must resume with --forceinstall, keeping the force semantics ──
# -fi implies -i, so the resume must carry --forceinstall INSTEAD of --install
# (one flag preserving both halves) plus every other semantics-changing flag.
dir="$fixture/with-forceinstall"
make_case_workspace "$dir"
run_expecting_failure "$dir" 'with -fi' --forceinstall --no-deps --allow-broken-rustc --no-sync
for flag in --forceinstall --no-deps --allow-broken-rustc --no-sync; do
    if [[ "$RESUME_CMD" != *"$flag"* ]]; then
        printf 'with -fi: resume command dropped %s:\n  %s\n' "$flag" "$RESUME_CMD" >&2
        exit 1
    fi
done
if [[ "$RESUME_CMD" == *"--install"* ]]; then
    printf 'with -fi: resume carries both --install and --forceinstall:\n  %s\n' \
        "$RESUME_CMD" >&2
    exit 1
fi
if [[ "$RESUME_CMD" != *"p3"* ]]; then
    printf 'with -fi: resume command does not name the unbuilt package:\n  %s\n' \
        "$RESUME_CMD" >&2
    exit 1
fi

# ─── A run without -i must NOT acquire --install on resume ──────────────────
dir="$fixture/without-install"
make_case_workspace "$dir"
run_expecting_failure "$dir" 'without -i' --no-deps --allow-broken-rustc
if [[ "$RESUME_CMD" == *"--install"* ]]; then
    printf 'without -i: resume command invented --install:\n  %s\n' "$RESUME_CMD" >&2
    exit 1
fi
if [[ "$RESUME_CMD" != *"p3"* ]]; then
    printf 'without -i: resume command does not name the unbuilt package:\n  %s\n' \
        "$RESUME_CMD" >&2
    exit 1
fi

# ─── The FAILED package itself must be in the resume set (2026-09-26 bug) ───
# The summary used to compute the resume set as selection minus
# succeeded+failed, which DROPPED the failed package: a user copying the
# suggested command rebuilt only the not-yet-attempted packages and silently
# left the failed one stale, so its dependents then built against the stale
# installed copy. The resume set is DATA now — the record's non-succeeded rows
# in row order, p2 (failed, must rebuild first) before p3 (never started) —
# and both the resume command and the summary follow it. The prose note that
# says so is rendering, pinned once in tests/dashboard.sh's prose section.
dir="$fixture/failed-included"
make_case_workspace "$dir"
run_expecting_failure "$dir" 'failed included' --no-deps --allow-broken-rustc --no-sync
if ! grep -qw 'p2' <<<"$RESUME_CMD"; then
    printf 'failed included: resume command drops the FAILED package:\n  %s\n' \
        "$RESUME_CMD" >&2
    exit 1
fi
if ! grep -qw 'p3' <<<"$RESUME_CMD"; then
    printf 'failed included: resume command drops the unbuilt package:\n  %s\n' \
        "$RESUME_CMD" >&2
    exit 1
fi
if [[ $(rr_row p2 status <<<"$RESUME_OUTPUT") != failed ]]; then
    printf 'failed included: p2 row is %s, want failed\n' \
        "$(rr_row p2 <<<"$RESUME_OUTPUT")" >&2
    exit 1
fi
if [[ $(rr_row p2 reason <<<"$RESUME_OUTPUT") != build-failed ]]; then
    printf 'failed included: p2 reason is %s, want build-failed\n' \
        "$(rr_row p2 reason <<<"$RESUME_OUTPUT")" >&2
    exit 1
fi
if [[ $(rr_row p3 status <<<"$RESUME_OUTPUT") != never-started ]]; then
    printf 'failed included: p3 row is %s, want never-started\n' \
        "$(rr_row p3 <<<"$RESUME_OUTPUT")" >&2
    exit 1
fi
if [[ $(rr_remaining <<<"$RESUME_OUTPUT" | tr '\n' ' ') != 'p2 p3 ' ]]; then
    printf 'failed included: resume set must be p2 (failed) then p3 (unbuilt), got: %s\n' \
        "$(rr_remaining <<<"$RESUME_OUTPUT" | tr '\n' ' ')" >&2
    exit 1
fi

# ─── An install-PLAN refusal fails the RUN and lands in the record ──────────
# R-F39/F25 family: the plan's status is never dropped. p2's built set is a
# PARTIAL split set (its second output never appears), so its install plan
# refuses with the named row instead of installing a subset or reporting
# "nothing to do" — p2's row is failed, the run outcome is failed, and the
# resume suggestion keeps --install and the not-yet-installed remainder.
(
    dir="$fixture/plan-refusal"
    make_workspace "$dir" 1 2 low
    make_install_conf "$dir/pacman.conf"
    add_package "$dir" p1 $'pkgver=1.0.0\npkgrel=1\narch=(any)'
    add_package "$dir" p2 $'pkgver=1.0.0\npkgrel=1\narch=(any)\npkgname=(p2 p2-extra)'
    add_package "$dir" p3 $'pkgver=1.0.0\npkgrel=1\narch=(any)'
    stub_sudo "$dir"
    stub_pacman "$dir"
    cat >"$dir/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
id=$(basename "$PWD")
: >"$PWD/$id-1.0.0-1-any.pkg.tar.zst"
# No second output for the split recipe: the built set stays PARTIAL, which
# the install plan must refuse by name — the build itself succeeds here.
printf 'fake makepkg %s\n' "$PWD"
exit 0
EOF
    chmod +x "$dir/bin/makepkg"
    set +e
    RESUME_OUTPUT=$(
        PATH="$dir/bin:$PATH" \
            GSA_STATE_DIR="$dir/state" \
            _IGNOREPKG_CONF="$dir/pacman.conf" \
            GSA_FAKE_PACMAN_LOG="$dir/pacman.log" \
            GSA_CPU_THREADS=8 \
            GSA_MEMORY_GIB=16 \
            fish "$dir/build-all.fish" --install --no-deps --allow-broken-rustc --no-sync p1 p2 p3 2>&1
    )
    rc=$?
    set -e
    if ((rc == 0)); then
        printf "plan refusal: the run succeeded although p2's install plan refused:\n%s\n" "$RESUME_OUTPUT" >&2
        exit 1
    fi
    if [[ $(rr_scalar outcome <<<"$RESUME_OUTPUT") != failed ]]; then
        printf 'plan refusal: run record outcome is %s, want failed:\n%s\n' \
            "$(rr_scalar outcome <<<"$RESUME_OUTPUT")" "$RESUME_OUTPUT" >&2
        exit 1
    fi
    if [[ $(rr_row p2 status <<<"$RESUME_OUTPUT") != failed ]]; then
        printf 'plan refusal: p2 row is %s, want failed:\n%s\n' \
            "$(rr_row p2 status <<<"$RESUME_OUTPUT")" "$RESUME_OUTPUT" >&2
        exit 1
    fi
    RESUME_CMD=$(grep '^  build-all.fish ' <<<"$RESUME_OUTPUT" | head -1)
    if [[ "$RESUME_CMD" != *"--install"* ]]; then
        printf 'plan refusal: resume command dropped --install:\n  %s\n' "$RESUME_CMD" >&2
        exit 1
    fi
    for pkg in p2 p3; do
        if ! grep -qw "$pkg" <<<"$RESUME_CMD"; then
            printf 'plan refusal: resume command drops %s:\n  %s\n' "$pkg" "$RESUME_CMD" >&2
            exit 1
        fi
    done
    if ! grep -Fq 'is incomplete' <<<"$RESUME_OUTPUT" ||
        ! grep -Fq 'p2-extra' <<<"$RESUME_OUTPUT"; then
        printf 'plan refusal: the omission was not named in the run output:\n%s\n' "$RESUME_OUTPUT" >&2
        exit 1
    fi
    if ! grep -rq 'refusing to install' "$dir/state" 2>/dev/null; then
        printf 'plan refusal: no named refusal row in the package transcript:\n%s\n' "$RESUME_OUTPUT" >&2
        exit 1
    fi
)

# ─── Ambient CPU/RAM pins are warned about, or a resume silently re-plans ───
# continuation_args warned about GSA_TARGET_CPU/GSA_STATE_DIR/
# GSA_VCS_SKIP_TOLERANCE but not GSA_CPU_THREADS/GSA_MEMORY_GIB — yet the
# core-solo job budget recomputes from them at every start, so a resume under
# different pins silently changed the plan (2026-10-05).
dir="$fixture/ambient-pins"
make_case_workspace "$dir"
run_expecting_failure "$dir" 'ambient pins' --no-deps --allow-broken-rustc --no-sync
for var in GSA_CPU_THREADS GSA_MEMORY_GIB; do
    if ! grep 'ambient environment' <<<"$RESUME_OUTPUT" | grep -q "$var"; then
        printf 'ambient pins: %s is not named in the ambient warning:\n%s\n' \
            "$var" "$RESUME_OUTPUT" >&2
        exit 1
    fi
done

printf 'resume command fixture: PASS\n'
