#!/usr/bin/env bash
set -euo pipefail

# `--skip`'s recipe gate is CONTENT based (contract §B.8/§B.11, blind review
# 2026-11-11 F): an archive records the PKGBUILD hash it was built from
# (makepkg's own `.BUILDINFO` `pkgbuild_sha256sum`), and that record is the
# gate. The mtime compare survives only for an archive WITHOUT the record.
#
# Why both directions matter:
#   * mtime under-reports: a restored/copied PKGBUILD carries an older mtime,
#     so the old gate skipped a genuinely changed recipe (§D.2's whole point);
#   * mtime over-reports: a content-identical rewrite (checkout, automated
#     touch) forced a rebuild the content did not ask for.
#
# The workspace, archives and state are synthetic under $TMPDIR; the pacman
# stub answers the payload gate and the makepkg stub (which runs only when the
# decision is BUILD) only needs to produce an archive.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-skip-content.XXXXXX")
trap '/usr/bin/sudo -n rm -rf -- "$fixture" 2>/dev/null || rm -rf -- "$fixture" 2>/dev/null || true' EXIT

fail() {
    printf 'skip-content-hash: %s\n' "$*" >&2
    exit 1
}

ws="$fixture/ws"
make_workspace "$ws" 1 1 low
add_package "$ws" p1 "$gsa_meta_any"
stub_pacman "$ws"
stub_makepkg "$ws"
export PATH="$ws/bin:$PATH"
export GSA_FAKE_PACMAN_LOG="$fixture/pacman.log"
: >"$GSA_FAKE_PACMAN_LOG"
recipe="$ws/packages/p1"
archive="$recipe/p1-1.0.0-1-any.pkg.tar.zst"

# The compiler build identity the drift gate compares (rule 6). Pin it with a
# stub so this fixture tests FRESHNESS, not the one-time clean
# (tests/toolchain-drift.sh owns the drift scenarios), and stage the marker the
# gate reads: a missing marker is itself drift and would force every claim in
# the fixture to build.
cat >"$ws/bin/gcc" <<'EOF'
#!/usr/bin/env bash
set -u
[[ ${1:-} == --version ]] || exit 2
printf 'gcc (fixture) %s\n' "${GSA_FAKE_GCC_VERSION:-fixture}"
EOF
chmod +x "$ws/bin/gcc"
mkdir -p "$fixture/state/toolchains"
# ASKED of the engine, never re-derived here: the identity's digest covers
# config bytes only the engine renders.
GSA_CONF_DIR="$ws/../.rr2-conf" "$GSA_TEST_GSA_BIN" --build-identity gcc \
    >"$fixture/state/toolchains/p1"

pkgbuild_hash() {
    sha256sum "$recipe/PKGBUILD" | cut -d' ' -f1
}

# stage_archive RECORDED_SHA [no-buildinfo] — the built set the claim keys
# to: a real tar whose `.PKGINFO` names p1 at the committed version and whose
# `.BUILDINFO` records the PKGBUILD hash makepkg would have stamped.
stage_archive() {
    local recorded=$1 stage="$fixture/stage"
    rm -rf "$stage"
    mkdir -p "$stage"
    printf 'pkgname = p1\npkgbase = p1\npkgver = 1.0.0-1\narch = any\n' >"$stage/.PKGINFO"
    local members=(.PKGINFO)
    if [[ ${2:-} != no-buildinfo ]]; then
        printf 'format = 2\npkgbuild_sha256sum = %s\n' "$recorded" >"$stage/.BUILDINFO"
        members+=(.BUILDINFO)
    fi
    rm -f "$archive"
    tar --zstd -cf "$archive" -C "$stage" "${members[@]}"
}

run_skip() {
    run_engine "$ws" -B --leaf --skip --state-dir "$fixture/state" p1
    printf '%s\n' "$FIXTURE_OUTPUT" >"$fixture/out"
}

# ─── A. the recorded hash matches: SKIP ─────────────────────────────────────
stage_archive "$(pkgbuild_hash)"
run_skip
((FIXTURE_RC == 0)) || fail "A: rc 0 expected, got $FIXTURE_RC:" "$fixture/out"
[ "$(rr2_plan p1 plan <<<"$FIXTURE_OUTPUT")" = skip ] ||
    fail "A: a matching PKGBUILD hash must skip: $(rr2_plan p1 <<<"$FIXTURE_OUTPUT")" "$fixture/out"
[ "$(rr2_plan p1 reason <<<"$FIXTURE_OUTPUT")" = ok ] ||
    fail "A: the skip reason is ok: $(rr2_plan p1 reason <<<"$FIXTURE_OUTPUT")" "$fixture/out"
printf 'A: a matching recorded PKGBUILD hash skips OK\n'

# ─── B. content changed, MTIME OLDER than the archive: must BUILD ───────────
# The old gate (`test PKGBUILD -nt archive`) skipped this: a restored or
# copied recipe carries an old mtime while its content moved.
printf 'pkgname=p1\npkgver=1.0.0\npkgrel=1\narch=(any)\noptions=(!strip)\n' \
    >"$recipe/PKGBUILD"
touch -d '2000-01-01' "$recipe/PKGBUILD"
run_skip
((FIXTURE_RC == 0)) || fail "B: rc 0 expected, got $FIXTURE_RC:" "$fixture/out"
[ "$(rr2_plan p1 plan <<<"$FIXTURE_OUTPUT")" = build ] ||
    fail "B: a changed PKGBUILD with an OLDER mtime must still build: $(rr2_plan p1 <<<"$FIXTURE_OUTPUT")" "$fixture/out"
[ "$(rr2_outcome p1 status <<<"$FIXTURE_OUTPUT")" = succeeded ] ||
    fail "B: the forced rebuild must succeed: $(rr2_outcome p1 <<<"$FIXTURE_OUTPUT")" "$fixture/out"
grep -q 'recipe-changed' "$fixture/out" ||
    fail 'B: the build decision must name the content change' "$fixture/out"
printf 'B: content truth beats an older mtime OK\n'

# ─── C. content identical, MTIME NEWER than the archive: must SKIP ──────────
# The build in B replaced the archive with the stub's; stage the current hash
# again, then touch the PKGBUILD newer without changing a byte.
stage_archive "$(pkgbuild_hash)"
touch -d '2030-01-01' "$recipe/PKGBUILD"
run_skip
((FIXTURE_RC == 0)) || fail "C: rc 0 expected, got $FIXTURE_RC:" "$fixture/out"
[ "$(rr2_plan p1 plan <<<"$FIXTURE_OUTPUT")" = skip ] ||
    fail "C: a content-identical PKGBUILD must not rebuild on mtime: $(rr2_plan p1 <<<"$FIXTURE_OUTPUT")" "$fixture/out"
printf 'C: content truth beats a newer mtime OK\n'

# ─── D. no recorded hash: the mtime fallback still governs ──────────────────
# An archive built by an older makepkg (or imported) carries no
# `.BUILDINFO`; a PKGBUILD newer than it must still rebuild.
stage_archive '' no-buildinfo
run_skip
((FIXTURE_RC == 0)) || fail "D: rc 0 expected, got $FIXTURE_RC:" "$fixture/out"
[ "$(rr2_plan p1 plan <<<"$FIXTURE_OUTPUT")" = build ] ||
    fail "D: without a recorded hash the mtime gate must rebuild: $(rr2_plan p1 <<<"$FIXTURE_OUTPUT")" "$fixture/out"
[ "$(rr2_outcome p1 status <<<"$FIXTURE_OUTPUT")" = succeeded ] ||
    fail "D: the mtime-forced rebuild must succeed: $(rr2_outcome p1 <<<"$FIXTURE_OUTPUT")" "$fixture/out"
grep -q 'recipe-newer' "$fixture/out" ||
    fail 'D: the mtime fallback must name the mtime cause' "$fixture/out"
printf 'D: the mtime fallback survives for an archive without a record OK\n'

printf 'skip-content-hash fixture: PASS (hash beats mtime both ways, fallback intact)\n'
