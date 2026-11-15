#!/usr/bin/env bash
set -euo pipefail

# Host prerequisites a build cannot START without (R2-maya-2).
#
# A box with no `fakeroot` used to report `failed 1 1 build-failed` with rc 4:
# the code for a real compile failure, whose cause ("Cannot find the fakeroot
# binary.") lived only in the package log. That blames the recipe for a host
# fact and sends the operator into a rebuild loop. The engine now asks
# makepkg's own `check_software` question BEFORE dispatch — naming the tool the
# way an absent compiler is named — and a lane that still hits makepkg's
# pre-build gate keeps that cause instead of `build-failed`.
#
# Pinned here, one ( subshell ) section each:
#   A. a PATH without `fakeroot` refuses pre-dispatch (rc 3): the prose names
#      the program AND the package that provides it, every row is
#      `never-started - - host-prerequisite-missing`, and NO makepkg ran;
#   B. the gate is about a BUILD: a selection whose only node is already built
#      spawns nothing, so the same fakeroot-less PATH is not refused (rc 0) —
#      a gate that fired here would refuse a run that never calls makepkg;
#   C. makepkg exit 15 (`E_MISSING_MAKEPKG_DEPS`) on a box that DOES have the
#      tool (a site file or a mid-run change can still get there) is
#      `failed 1 host-prerequisite-missing`, never `build-failed`;
#   D. makepkg exit 8 (`E_INSTALL_DEPS_FAILED` — a declared dependency the
#      mirrors could not install) is `failed 1 dependency-install-failed`.
#
# Red-first: without the pre-dispatch gate A reports rc 4 `build-failed`;
# without the classification C and D both read `build-failed`.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-host-prereq.XXXXXX")
# A build run is privileged, so its state root is root-owned by design (§J.5).
trap '/usr/bin/sudo -n rm -rf -- "$fixture" 2>/dev/null || rm -rf -- "$fixture" 2>/dev/null || true' EXIT

fail() {
    printf 'host-prerequisite: %s\n' "$1" >&2
    if [ -n "${2:-}" ] && [ -f "$2" ]; then
        sed 's/^/    /' "$2" >&2
    fi
    exit 1
}

ws="$fixture/ws"
make_workspace "$ws" 1 1 low
add_package "$ws" p1

# The makepkg stub records every spawn, so "no makepkg ran" is observable.
cat >"$ws/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'makepkg %s\n' "$PWD" >>"${GSA_FAKE_MAKEPKG_LOG:?}"
id=$(basename "$PWD")
dest=${GSA_LANE_PKGDEST:-$PWD}
stage="$dest/.stage-$id-$$"
mkdir -p "$stage"
{
    printf 'pkgbase = %s\n' "$id"
    printf 'pkgname = %s\n' "$id"
    printf 'pkgver = 1.0.0-1\n'
    printf 'arch = any\n'
} >"$stage/.PKGINFO"
tar --zstd -cf "$dest/$id-1.0.0-1-any.pkg.tar.zst" -C "$stage" .PKGINFO
rm -rf -- "$stage"
EOF
chmod +x "$ws/bin/makepkg"

# The box under test: every /usr/bin tool EXCEPT fakeroot — exactly what
# makepkg's `type -p fakeroot` sees on a host without it.
farm="$fixture/farm"
mkdir -p "$farm"
for tool_bin in /usr/bin/*; do
    [ "${tool_bin##*/}" = fakeroot ] && continue
    ln -s "$tool_bin" "$farm/${tool_bin##*/}" 2>/dev/null || true
done

# ─── A. no fakeroot: refused pre-dispatch, naming the tool ─────────────────
(
    set -euo pipefail
    export PATH="$ws/bin:$farm"
    export GSA_FAKE_MAKEPKG_LOG="$fixture/a/makepkg.log"
    export GSA_CPU_THREADS=8 GSA_MEMORY_GIB=16
    mkdir -p "$fixture/a"

    run_engine "$ws" -B --leaf --no-sync \
        --state-dir "$fixture/a/state" --build-dir "$fixture/a/build" p1
    printf '%s\n' "$FIXTURE_OUTPUT" >"$fixture/a/out.txt"

    [ "$FIXTURE_RC" -eq 3 ] ||
        fail "A: a host without fakeroot exited $FIXTURE_RC, want the refusal class 3 (§G.1):" "$fixture/a/out.txt"
    vgrep "$FIXTURE_OUTPUT" -Fq 'fakeroot' ||
        fail 'A: the refusal does not name the missing program:' "$fixture/a/out.txt"
    vgrep "$FIXTURE_OUTPUT" -Fq 'pacman -S fakeroot' ||
        fail 'A: the refusal does not name the package that provides it:' "$fixture/a/out.txt"
    [ "$(rr2_outcome p1 <"$fixture/a/out.txt")" = 'p1 never-started - - host-prerequisite-missing' ] ||
        fail "A: row wrong: $(rr2_outcome p1 <"$fixture/a/out.txt")" "$fixture/a/out.txt"
    [ "$(rr2_scalar outcome <"$fixture/a/out.txt")" = refused ] ||
        fail "A: run outcome wrong: $(rr2_scalar outcome <"$fixture/a/out.txt")" "$fixture/a/out.txt"
    [ ! -s "$fixture/a/makepkg.log" ] ||
        fail 'A: the run refused but still spawned makepkg:' "$fixture/a/makepkg.log"
)

# ─── B. nothing to build is nothing to require ─────────────────────────────
# The same fakeroot-less PATH, but the only node is already built: prepare
# settles it as a skip, no lane spawns, so no prerequisite is owed.
(
    set -euo pipefail
    export GSA_FAKE_MAKEPKG_LOG="$fixture/b/makepkg.log"
    export GSA_CPU_THREADS=8 GSA_MEMORY_GIB=16
    mkdir -p "$fixture/b"

    # 1. build it once on the normal PATH (the archive is what step 2 skips).
    export PATH="$ws/bin:$PATH"
    run_engine "$ws" -B --leaf --no-sync \
        --state-dir "$fixture/b/state" --build-dir "$fixture/b/build" p1
    printf '%s\n' "$FIXTURE_OUTPUT" >"$fixture/b/prime.txt"
    [ "$FIXTURE_RC" -eq 0 ] ||
        fail "B: the priming build exited $FIXTURE_RC, want 0" "$fixture/b/prime.txt"
    : >"$fixture/b/makepkg.log"

    # 2. same selection, host without fakeroot: `--skip-built` claims the
    #    archive, so no makepkg is needed and the gate must stay silent (a
    #    refusal here would be a false refusal).
    export PATH="$ws/bin:$farm"
    run_engine "$ws" -B --leaf --skip-built --no-sync \
        --state-dir "$fixture/b/state" --build-dir "$fixture/b/build" p1
    printf '%s\n' "$FIXTURE_OUTPUT" >"$fixture/b/out.txt"
    [ "$FIXTURE_RC" -eq 0 ] ||
        fail "B: an already-built selection was refused ($FIXTURE_RC) on a host without fakeroot:" "$fixture/b/out.txt"
    [ ! -s "$fixture/b/makepkg.log" ] ||
        fail 'B: the skipped run spawned makepkg:' "$fixture/b/makepkg.log"
)

# ─── C/D. makepkg's own pre-build gates keep their cause ───────────────────
# A fakeroot stub satisfies the pre-dispatch gate (the engine's probe asks
# `type -p`), so these exercise the LANE half: the two exits that mean "this
# box could not start the build".
lane_bin="$fixture/lane-bin"
mkdir -p "$lane_bin"
printf '#!/bin/sh\nexit 0\n' >"$lane_bin/fakeroot"
chmod +x "$lane_bin/fakeroot"
cat >"$ws/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -eu
exit "${GSA_FAKE_MAKEPKG_RC:?}"
EOF
chmod +x "$ws/bin/makepkg"

for case in '15 host-prerequisite-missing' '8 dependency-install-failed'; do
    (
        set -euo pipefail
        rc=${case%% *}
        want=${case##* }
        export PATH="$lane_bin:$ws/bin:$PATH"
        export GSA_FAKE_MAKEPKG_RC="$rc"
        export GSA_CPU_THREADS=8 GSA_MEMORY_GIB=16
        dir="$fixture/lane-$rc"
        mkdir -p "$dir"

        run_engine "$ws" -B --leaf --no-sync \
            --state-dir "$dir/state" --build-dir "$dir/build" p1
        printf '%s\n' "$FIXTURE_OUTPUT" >"$dir/out.txt"

        [ "$FIXTURE_RC" -eq 4 ] ||
            fail "C/D: makepkg rc $rc exited $FIXTURE_RC, want the cone-stop 4 (§G.1):" "$dir/out.txt"
        [ "$(rr2_outcome p1 reason <"$dir/out.txt")" = "$want" ] ||
            fail "C/D: makepkg rc $rc is $(rr2_outcome p1 reason <"$dir/out.txt"), want $want (a pre-build gate is not a recipe failure):" "$dir/out.txt"
        if vgrep "$FIXTURE_OUTPUT" -Fq 'reason=build-failed'; then
            fail "C/D: makepkg rc $rc still claims build-failed:" "$dir/out.txt"
        fi
    )
done
