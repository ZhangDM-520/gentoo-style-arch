#!/usr/bin/env bash
set -euo pipefail

# ABI-drift guard layer 3 — the install-time fatal provide-diff refusal
# (build-all.fish abi_provide_refusals, an install-plan step beside
# pgo_payload_refusals, BEFORE the force branch). Through the hidden
# `--install-decide <checked|force>` seam — no pacman transaction, no sudo,
# no flock, no makepkg — this pins:
#
#   A. a bare soname provide that MOVES against the installed database
#      (libgreet.so=1-64 → libgreet.so=2-64, same pkgname) while the
#      installed consumer closure is NOT in the transaction → silent
#      `refuse abi-soname` + `refuse abi-consumer` rows, rc 1 (both modes);
#   B. closure complete: the consumer's archive rides in the same
#      transaction → rc 0, plain `install` rows;
#   C. nothing to protect: the consumer is not installed → rc 0;
#   D. no provide diff (same soname versions) → rc 0;
#   E. a DISAPPEARING provide (built archive drops the soname entirely) →
#      `refuse abi-soname … <installed-ver> -` + consumer rows, rc 1;
#   F. fresh install (the pkgname is not installed at all) → rc 0: nothing
#      installed can lose a provide;
#   G. the force branch does NOT bypass the gate: the REAL -i executor
#      renders the same refusal and aborts before pacman -U.
#   H. a spaced archive path survives the codec round trip (R-F22).
#   I. Stock→house swap (the run #31 blind spot): the archive's pkgname is
#      NOT installed but its stock counterpart (abi_stock_name) IS, with a
#      drifted soname surface and an uncovered consumer closure → the SAME
#      `refuse abi-soname` + `refuse abi-consumer` rows (pkgname field stays
#      the archive's pkgname; the installed side comes from the counterpart),
#      rc 1, and zero mutating invocations (no pacman -U, no sudo — the
#      decision half's only pacman traffic is read-only -Qi/-Q probes).
#   J. the swap with an IDENTICAL soname surface is a clean pass even with
#      the consumer closure open — only the surface MOVING strands consumers.
#      (The double-fresh shape — neither the pkgname nor the stock
#      counterpart installed — is case F: one more read-only probe, same
#      clean plan.)
#   K. in-run repair coverage (2026-10-07, run #48 wall): the surface
#      consumer scheduled strictly AFTER the provider in the exported run
#      order (_GSA_RUN_ORDER — run_lanes' topological selection) is rebuilt
#      and reinstalled by THIS run, so the move lands with a repair: clean
#      plan carrying the non-refusal row
#      `repair <archive> <consumer> <provider-id>`, no refusal rows;
#   L. the consumer scheduled BEFORE the provider in the run order → the
#      usual refusals (nothing later repairs it);
#   M. the consumer absent from the run order → the usual refusals (the run
#      never rebuilds it);
#   N. the REAL -i executor cycle: a run whose selection orders the consumer
#      after the provider plans `repair`, records the forced-rebuild marker
#      under $GSA_STATE_DIR/abi-repair/ BEFORE pacman -U (the stub snapshots
#      the marker dir at every transaction), renders the note into the
#      package log, and consumes the marker when the consumer's own install
#      lands.
#
# The pacman stub is read-only (-Qi/-Q probes); every case asserts no
# `pacman -U` ever ran. Scratch workspaces under $TMPDIR only.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/tests/lib/fixture-lib.bash"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-abi-drift-install.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    printf 'abi-drift-install fixture: %s\n' "$1" >&2
    exit 1
}

# planrow FIELD... — the plan-row codec's tab framing (R-F22 grammar): row
# expectations must frame fields exactly as install_plan prints them.
planrow() {
    local IFS=$'\t'
    printf '%s' "$*"
}

checks=0

# make_archive DIR PKGNAME PROVIDES-LINE... — a makepkg-shaped archive with
# just .PKGINFO (the gate reads metadata, never payload bytes).
make_archive() {
    local dir=$1 name=$2
    shift 2
    local stage="$tmp/stage-$name"
    rm -rf -- "$stage"
    mkdir -p "$stage"
    {
        printf 'pkgname = %s\n' "$name"
        printf 'pkgver = 1.0.0-1\n'
        local line
        for line in "$@"; do
            printf 'provides = %s\n' "$line"
        done
    } >"$stage/.PKGINFO"
    tar --zstd -cf "$dir/packages/$name/$name-1.0.0-1-x86_64.pkg.tar.zst" -C "$stage" .
    rm -rf -- "$stage"
}

write_srcinfo() {
    local dir=$1 base=$2
    shift 2
    {
        printf 'pkgbase = %s\n' "$base"
        printf 'pkgname = %s\n' "$base"
        printf '%s\n' "$@"
    } >"$dir/.SRCINFO"
}

ws="$tmp/ws"
make_workspace "$ws" 1 2 low
make_install_conf "$ws/pacman.conf" # this run's IgnorePkg registration target (never the host's)
add_package "$ws" libs-git "$gsa_meta_any"
add_package "$ws" app-git "$gsa_meta_any"
set_topology_record "$ws" app-git git 'libs-git'
write_srcinfo "$ws/packages/libs-git" libs-git $'\tprovides = libgreet.so'
write_srcinfo "$ws/packages/app-git" app-git $'\tdepends = libgreet.so'

# The transaction's archives: provider with the BUMPED auto-versioned provide,
# consumer with a stable one.
libs_arch="$ws/packages/libs-git/libs-git-1.0.0-1-x86_64.pkg.tar.zst"
app_arch="$ws/packages/app-git/app-git-1.0.0-1-x86_64.pkg.tar.zst"
make_archive "$ws" libs-git 'libgreet.so=2-64'
make_archive "$ws" app-git 'libapp.so=1-64'

# The pacman stub: read-only probes only. Arguments arrive `pacman -Qi -- NAME`
# (the builder passes `--` before names), so the stub drops `--` before
# reading them. -Qi NAME answers installed provides from GSA_FAKE_QI_LIBS /
# GSA_FAKE_QI_APP (empty = not installed, exit 1 — the conservative
# direction); -Q NAME answers membership from GSA_FAKE_APP_INSTALLED; -U must
# NEVER run in any decide case.
cat >"$ws/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'pacman %s\n' "$*" >>"${GSA_FAKE_PACMAN_LOG:?}"
args=()
for a in "$@"; do
    [[ $a == -- ]] && continue
    args+=("$a")
done
case ${args[0]:-} in
-Qi)
    case ${args[1]:-} in
    libs-git)
        [[ -n ${GSA_FAKE_QI_LIBS:-} ]] || exit 1
        printf '%s\n' "$GSA_FAKE_QI_LIBS"
        ;;
    app-git)
        [[ -n ${GSA_FAKE_QI_APP:-} ]] || exit 1
        printf '%s\n' "$GSA_FAKE_QI_APP"
        ;;
    libs)
        # The STOCK counterpart of libs-git — the swap path's comparison
        # surface (empty = nothing installed for it = true fresh install).
        [[ -n ${GSA_FAKE_QI_STOCK:-} ]] || exit 1
        printf '%s\n' "$GSA_FAKE_QI_STOCK"
        ;;
    *) exit 1 ;;
    esac
    ;;
-Q)
    if [[ ${args[1]:-} == app-git ]]; then
        [[ ${GSA_FAKE_APP_INSTALLED:-0} == 1 ]] && exit 0
    fi
    exit 1
    ;;
-Ql)
    # File listing for the link-truth probe (gate fix v2): one synthetic ELF
    # path per installed member; the readelf stub answers its DT_NEEDED.
    if [[ ${args[1]:-} == app-git && ${GSA_FAKE_APP_INSTALLED:-0} == 1 ]]; then
        printf '%s /usr/lib/lib-app-git.so\n' "${args[1]}"
        exit 0
    fi
    exit 1
    ;;
-Qp) exit 1 ;;
-U)
    if [[ ${GSA_FAKE_ACCEPT_U:-0} == 1 ]]; then
        # N's oracle: snapshot the pending ABI-repair markers at transaction
        # time — the contract is "written before the move lands, consumed
        # only after the marked recipe's own install".
        if [[ -n ${GSA_FAKE_MARKER_SNAPSHOT:-} ]]; then
            {
                printf 'U:%s:' "$*"
                ls "${GSA_STATE_DIR:-/nonexistent}/abi-repair" 2>/dev/null | tr '\n' ' '
                printf '\n'
            } >>"$GSA_FAKE_MARKER_SNAPSHOT"
        fi
        exit 0
    fi
    printf 'UNEXPECTED pacman -U in a decide-only run\n' >&2
    exit 99
    ;;
esac
exit 0
EOF
chmod +x "$ws/bin/pacman"

# The stub readelf: DT_NEEDED truth for the link filter. app-git LINKS the
# provider's soname (`libgreet.so.1-64`) — the fixture's installed consumer
# is exactly the class the gate protects; a consumer that never references
# the moving soname must not gate (pinned in tests/abi-batch-policy.sh G5).
cat >"$ws/bin/readelf" <<'EOF'
#!/usr/bin/env bash
set -u
for a in "$@"; do
    [[ $a == -* ]] && continue
    printf 'File: %s\n' "$a"
    case $a in
    *app-git*)
        printf ' 0x0000000000000001 (NEEDED)             Shared library: [libgreet.so.1-64]\n'
        ;;
    *)
        printf ' 0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]\n'
        ;;
    esac
done
exit 0
EOF
chmod +x "$ws/bin/readelf"

# decide MODE [ARCHIVE...] — the seam. Stdout only (the rows) in
# FIXTURE_OUTPUT; stderr is kept apart so user fish-config noise can never
# disturb the row assertions (install-conflict-ask's convention).
decide() {
    set +e
    FIXTURE_OUTPUT=$(env \
        PATH="$ws/bin:$PATH" \
        GSA_STATE_DIR="$ws/state" \
        _IGNOREPKG_CONF="$ws/pacman.conf" \
        GSA_FAKE_PACMAN_LOG="$ws/pacman.log" \
        GSA_FAKE_QI_LIBS="$GSA_FAKE_QI_LIBS" \
        GSA_FAKE_QI_APP="$GSA_FAKE_QI_APP" \
        GSA_FAKE_QI_STOCK="${GSA_FAKE_QI_STOCK:-}" \
        GSA_FAKE_APP_INSTALLED="$GSA_FAKE_APP_INSTALLED" \
        _GSA_RUN_ORDER="${_GSA_RUN_ORDER:-}" \
        fish "$ws/build-all.fish" --install-decide "$@" 2>"$ws/decide.err")
    FIXTURE_RC=$?
    set -e
}

assert_no_u() {
    grep -q -- 'pacman -U' "$ws/pacman.log" 2>/dev/null &&
        fail "$1: the decide seam must never touch pacman -U: $(cat "$ws/pacman.log")"
    checks=$((checks + 1))
}

# Installed state for the drift cases: old provider surface + an INSTALLED
# consumer (the closure member that would break). Each case re-sets these
# explicitly — inline VAR=… assignments leak into a bash function's shell.
GSA_FAKE_QI_LIBS='Name : libs-git
Version : 1.0.0-1
Provides : libgreet.so=1-64'
GSA_FAKE_QI_APP='Name : app-git
Version : 1.0.0-1
Provides : libapp.so=1-64'
GSA_FAKE_APP_INSTALLED=1

# ─── A. provide-diff + open closure → refusal rows, rc 1 ───────────────────
: >"$ws/pacman.log"
decide force "$libs_arch"
((FIXTURE_RC == 1)) ||
    fail "A: a moving soname provide with an open closure must refuse (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
expected="$(planrow refuse abi-soname "$libs_arch" libs-git libgreet.so 1-64 2-64)
$(planrow refuse abi-consumer "$libs_arch" app-git)"
[[ $FIXTURE_OUTPUT == "$expected" ]] ||
    fail "A: wrong refusal rows (want tab-framed plan_row output).
want:
$expected
got:
$FIXTURE_OUTPUT"
assert_no_u A
checks=$((checks + 2))

# Checked mode refuses the same plan (the gate sits before the force branch,
# so neither mode routes around it).
: >"$ws/pacman.log"
decide checked "$libs_arch"
((FIXTURE_RC == 1)) || fail "A2: checked mode must refuse too (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
[[ $FIXTURE_OUTPUT == "$expected" ]] || fail "A2: checked mode rows differ: $FIXTURE_OUTPUT"
assert_no_u A2
checks=$((checks + 2))

# ─── B. closure complete: the consumer rides in the transaction ────────────
: >"$ws/pacman.log"
decide force "$libs_arch" "$app_arch"
((FIXTURE_RC == 0)) ||
    fail "B: a complete closure must plan cleanly (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
grep -Fxq "$(planrow install "$libs_arch")" <<<"$FIXTURE_OUTPUT" ||
    fail "B: the provider must be planned for install: $FIXTURE_OUTPUT"
grep -Fxq "$(planrow install "$app_arch")" <<<"$FIXTURE_OUTPUT" ||
    fail "B: the consumer must be planned for install: $FIXTURE_OUTPUT"
assert_no_u B
checks=$((checks + 3))

# ─── C. consumer not installed — nothing to protect ────────────────────────
GSA_FAKE_APP_INSTALLED=0
GSA_FAKE_QI_APP=''
: >"$ws/pacman.log"
decide force "$libs_arch"
((FIXTURE_RC == 0)) ||
    fail "C: an uninstalled consumer must not gate (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
grep -Fq 'refuse' <<<"$FIXTURE_OUTPUT" &&
    fail "C: no refusal rows expected: $FIXTURE_OUTPUT"
assert_no_u C
checks=$((checks + 2))

# ─── D. no provide diff → clean plan ───────────────────────────────────────
GSA_FAKE_APP_INSTALLED=1
GSA_FAKE_QI_APP='Name : app-git
Version : 1.0.0-1
Provides : libapp.so=1-64'
GSA_FAKE_QI_LIBS='Name : libs-git
Version : 1.0.0-1
Provides : libgreet.so=2-64'
: >"$ws/pacman.log"
decide force "$libs_arch"
((FIXTURE_RC == 0)) ||
    fail "D: an unchanged provide surface must plan cleanly (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
grep -Fxq "$(planrow install "$libs_arch")" <<<"$FIXTURE_OUTPUT" ||
    fail "D: the archive must still be planned for install: $FIXTURE_OUTPUT"
assert_no_u D
checks=$((checks + 2))

# ─── E. disappearing provide → refusal with the '-' built side ─────────────
make_archive "$ws" libs-git 'libother.so=1-64'
GSA_FAKE_QI_LIBS='Name : libs-git
Version : 1.0.0-1
Provides : libgreet.so=1-64'
: >"$ws/pacman.log"
decide force "$libs_arch"
((FIXTURE_RC == 1)) ||
    fail "E: a disappearing soname provide must refuse (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
grep -Fxq "$(planrow refuse abi-soname "$libs_arch" libs-git libgreet.so 1-64 -)" <<<"$FIXTURE_OUTPUT" ||
    fail "E: missing disappear row: $FIXTURE_OUTPUT"
grep -Fxq "$(planrow refuse abi-consumer "$libs_arch" app-git)" <<<"$FIXTURE_OUTPUT" ||
    fail "E: missing consumer row: $FIXTURE_OUTPUT"
assert_no_u E
checks=$((checks + 3))

# ─── F. fresh install — the pkgname is not installed at all ────────────────
GSA_FAKE_QI_LIBS=''
: >"$ws/pacman.log"
decide force "$libs_arch"
((FIXTURE_RC == 0)) ||
    fail "F: a fresh install cannot lose provides (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
grep -Fq 'refuse' <<<"$FIXTURE_OUTPUT" &&
    fail "F: no refusal rows expected: $FIXTURE_OUTPUT"
assert_no_u F
checks=$((checks + 2))

# ─── G. the force branch does not bypass the gate ──────────────────────────
# -fi/-ia plan in force mode; force bypasses only the same-version SKIP. Pin
# the RENDERING through the real executor: the refusal must abort the run
# before any pacman -U, naming the move and the uncovered consumer.
make_archive "$ws" libs-git 'libgreet.so=2-64'
GSA_FAKE_QI_LIBS='Name : libs-git
Version : 1.0.0-1
Provides : libgreet.so=1-64'
stub_sudo "$ws"
stub_makepkg "$ws"
# A missing GCC build-identity stamp makes the toolchain-drift clean delete
# every cached archive before the build (the drift feature's own contract) —
# which would silently destroy this case's pre-made bumped-provide archive.
# Stamp the CURRENT toolchain identity so the workspace looks like a healthy
# build and this case stays about the ABI gate, not toolchain drift.
mkdir -p "$ws/state/toolchains"
gccline=$(LC_ALL=C gcc --version 2>/dev/null | head -1)
[[ -n $gccline ]] || gccline='gcc unavailable'
printf '%s\n%s\n' "$ws/packages/libs-git" "$gccline" >"$ws/state/toolchains/libs-git"
: >"$ws/pacman.log"
run_builder env \
    PATH="$ws/bin:$PATH" \
    GSA_STATE_DIR="$ws/state" \
    _IGNOREPKG_CONF="$ws/pacman.conf" \
    GSA_FAKE_PACMAN_LOG="$ws/pacman.log" \
    GSA_FAKE_QI_LIBS="$GSA_FAKE_QI_LIBS" \
    GSA_FAKE_QI_APP="$GSA_FAKE_QI_APP" \
    GSA_FAKE_APP_INSTALLED=1 \
    GSA_CPU_THREADS=8 GSA_MEMORY_GIB=16 \
    fish "$ws/build-all.fish" --allow-broken-rustc --no-deps --no-sync -i libs-git
((FIXTURE_RC != 0)) || fail "G: the -i run must fail on the refused plan: $FIXTURE_OUTPUT"
# The -i lane renders its refusals into the package log (quiet sink — lanes
# never write to the terminal), so that transcript is the assertion surface.
g_log="$ws/state/logs/libs-git.log"
[[ -f $g_log ]] || fail "G: no package log was written: $FIXTURE_OUTPUT"
grep -Fq 'soname provide libgreet.so moves 1-64 -> 2-64' "$g_log" ||
    fail "G: the refusal must render the move: $(cat "$g_log")"
grep -Fq 'installed consumer app-git is not in this transaction' "$g_log" ||
    fail "G: the refusal must name the consumer: $(cat "$g_log")"
assert_no_u G
checks=$((checks + 3))

# ─── H. a spaced archive path survives the abi refusal rows (R-F22) ────────
# The refusal rows carry the archive path too; the tab-framed codec must
# deliver it to the seam/consumer intact (the old space-joined row truncated
# at the first space and the rendering named a nonexistent archive).
(
    mkdir -p "$ws/spaced dir"
    make_archive "$ws" libs-git 'libgreet.so=2-64'
    sp_arch="$ws/spaced dir/libs-git-1.0.0-1-x86_64.pkg.tar.zst"
    cp "$libs_arch" "$sp_arch"
    GSA_FAKE_QI_LIBS='Name : libs-git
Version : 1.0.0-1
Provides : libgreet.so=1-64'
    GSA_FAKE_QI_APP='Name : app-git
Version : 1.0.0-1
Provides : libapp.so=1-64'
    GSA_FAKE_APP_INSTALLED=1
    : >"$ws/pacman.log"
    decide force "$sp_arch"
    ((FIXTURE_RC == 1)) ||
        fail "H: a moving provide over a spaced path must refuse (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    sp_expected="$(planrow refuse abi-soname "$sp_arch" libs-git libgreet.so 1-64 2-64)
$(planrow refuse abi-consumer "$sp_arch" app-git)"
    [[ $FIXTURE_OUTPUT == "$sp_expected" ]] ||
        fail "H: the spaced path did not survive the refusal rows.
want:
$sp_expected
got:
$FIXTURE_OUTPUT"
    assert_no_u H
    checks=$((checks + 2))
)

# ─── I. Stock→house swap: drifted counterpart surface → the same refusals ──
# The run #31 blind spot: nothing is installed for the ARCHIVE's pkgname
# (libs-git) — the old gate read that as a fresh install and skipped — but the
# stock counterpart (`libs`, abi_stock_name) IS installed and its soname
# surface MOVES (`libgreet.so=1-64` → the build's `=2-64`), with the
# consumer closure open. The rows must be the same-pkgname shape (the
# pkgname field stays the ARCHIVE's pkgname; only the installed side comes
# from the counterpart's record), and the refusal must abort before any
# MUTATING invocation. The decision half's only installed-database traffic is
# the read-only -Qi/-Q probes the gate cannot see the drift without — the
# "zero pacman/sudo" contract is zero transactions/escalations, pinned below
# by the log shapes. The sudo stub is an ORACLE (logs to a path derived from
# itself, so no env can silence it): any escalation at all must show up.
(
    set -euo pipefail
    cat >"$ws/bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -u
log=$(dirname "$0")/../sudo.log
printf 'sudo %s\n' "$*" >>"$log"
exit 99
EOF
    chmod +x "$ws/bin/sudo"
    make_archive "$ws" libs-git 'libgreet.so=2-64'
    GSA_FAKE_QI_LIBS=''
    GSA_FAKE_QI_STOCK='Name : libs
Version : 1.0.0-1
Provides : libgreet.so=1-64'
    GSA_FAKE_QI_APP='Name : app-git
Version : 1.0.0-1
Provides : libapp.so=1-64'
    GSA_FAKE_APP_INSTALLED=1
    : >"$ws/pacman.log"
    : >"$ws/sudo.log"
    decide force "$libs_arch"
    ((FIXTURE_RC == 1)) ||
        fail "I: a Stock→house swap moving the soname surface must refuse (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    i_expected="$(planrow refuse abi-soname "$libs_arch" libs-git libgreet.so 1-64 2-64)
$(planrow refuse abi-consumer "$libs_arch" app-git)"
    [[ $FIXTURE_OUTPUT == "$i_expected" ]] ||
        fail "I: wrong swap refusal rows (want tab-framed plan_row output).
want:
$i_expected
got:
$FIXTURE_OUTPUT"
    if grep -Evq '^pacman -(Qi|Ql|Q) ' "$ws/pacman.log"; then
        fail "I: the refusal path must make only read-only pacman probes: $(cat "$ws/pacman.log")"
    fi
    assert_no_u I
    [[ ! -s "$ws/sudo.log" ]] ||
        fail "I: a refused plan must never escalate via sudo: $(cat "$ws/sudo.log")"
    checks=$((checks + 3))
)

# ─── J. Stock→house swap with an IDENTICAL soname surface → clean plan ─────
# Same swap shape as I (nothing installed for libs-git, `libs` installed,
# consumer closure open) but the counterpart's surface matches the archive's
# exactly: a drop-in swap must plan cleanly — only a surface that MOVES
# strands consumers.
(
    set -euo pipefail
    make_archive "$ws" libs-git 'libgreet.so=2-64'
    GSA_FAKE_QI_LIBS=''
    GSA_FAKE_QI_STOCK='Name : libs
Version : 1.0.0-1
Provides : libgreet.so=2-64'
    GSA_FAKE_QI_APP='Name : app-git
Version : 1.0.0-1
Provides : libapp.so=1-64'
    GSA_FAKE_APP_INSTALLED=1
    : >"$ws/pacman.log"
    : >"$ws/sudo.log"
    decide force "$libs_arch"
    ((FIXTURE_RC == 0)) ||
        fail "J: a drop-in swap (identical soname provides) must plan cleanly (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    grep -Fxq "$(planrow install "$libs_arch")" <<<"$FIXTURE_OUTPUT" ||
        fail "J: the swap archive must be planned for install: $FIXTURE_OUTPUT"
    grep -Fq 'refuse' <<<"$FIXTURE_OUTPUT" &&
        fail "J: no refusal rows expected: $FIXTURE_OUTPUT"
    if grep -Evq '^pacman -(Qi|Ql|Q) ' "$ws/pacman.log"; then
        fail "J: the decide seam made a non-probe pacman call: $(cat "$ws/pacman.log")"
    fi
    [[ ! -s "$ws/sudo.log" ]] ||
        fail "J: the decide seam must never escalate via sudo: $(cat "$ws/sudo.log")"
    checks=$((checks + 3))
)

# ─── K. in-run repair coverage: consumer scheduled after the provider ─────
# The -i contract rebuilds the consumer against the moved surface later in
# the SAME run (its install is what repairs the move), so a consumer in the
# exported run order strictly after the provider is COVERED: the plan is
# clean and carries the non-refusal `repair` row the executor turns into the
# forced-rebuild marker. This is the run #48 wall: niri-spicy-git WAS in the
# selection, ordered after libdisplay-info-git, and the gate refused anyway.
(
    set -euo pipefail
    make_archive "$ws" libs-git 'libgreet.so=2-64'
    GSA_FAKE_QI_LIBS='Name : libs-git
Version : 1.0.0-1
Provides : libgreet.so=1-64'
    GSA_FAKE_QI_APP='Name : app-git
Version : 1.0.0-1
Provides : libapp.so=1-64'
    GSA_FAKE_APP_INSTALLED=1
    _GSA_RUN_ORDER='libs-git app-git'
    : >"$ws/pacman.log"
    decide force "$libs_arch"
    ((FIXTURE_RC == 0)) ||
        fail "K: a consumer scheduled after the provider must be repaired in-run (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    k_expected="$(planrow repair "$libs_arch" app-git libs-git)
$(planrow install "$libs_arch")"
    [[ $FIXTURE_OUTPUT == "$k_expected" ]] ||
        fail "K: wrong repair plan rows (want tab-framed plan_row output).
want:
$k_expected
got:
$FIXTURE_OUTPUT"
    assert_no_u K
)
checks=$((checks + 2))

# ─── L. the consumer scheduled BEFORE the provider → refusals ─────────────
(
    set -euo pipefail
    _GSA_RUN_ORDER='app-git libs-git'
    : >"$ws/pacman.log"
    decide force "$libs_arch"
    ((FIXTURE_RC == 1)) ||
        fail "L: a consumer ordered before the provider is never repaired later (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    l_expected="$(planrow refuse abi-soname "$libs_arch" libs-git libgreet.so 1-64 2-64)
$(planrow refuse abi-consumer "$libs_arch" app-git)"
    [[ $FIXTURE_OUTPUT == "$l_expected" ]] ||
        fail "L: wrong refusal rows.
want:
$l_expected
got:
$FIXTURE_OUTPUT"
    assert_no_u L
)
checks=$((checks + 2))

# ─── M. the consumer absent from the run order → refusals ─────────────────
(
    set -euo pipefail
    _GSA_RUN_ORDER='libs-git other-git'
    : >"$ws/pacman.log"
    decide force "$libs_arch"
    ((FIXTURE_RC == 1)) ||
        fail "M: a consumer the run never rebuilds must refuse (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    m_expected="$(planrow refuse abi-soname "$libs_arch" libs-git libgreet.so 1-64 2-64)
$(planrow refuse abi-consumer "$libs_arch" app-git)"
    [[ $FIXTURE_OUTPUT == "$m_expected" ]] ||
        fail "M: wrong refusal rows.
want:
$m_expected
got:
$FIXTURE_OUTPUT"
    assert_no_u M
)
checks=$((checks + 2))

# ─── N. the real -i executor: marker written before the move, consumed by
#        the consumer's own install ─────────────────────────────────────────
(
    set -euo pipefail
    make_archive "$ws" libs-git 'libgreet.so=2-64'
    make_archive "$ws" app-git 'libapp.so=1-64'
    GSA_FAKE_QI_LIBS='Name : libs-git
Version : 1.0.0-1
Provides : libgreet.so=1-64'
    GSA_FAKE_QI_APP='Name : app-git
Version : 1.0.0-1
Provides : libapp.so=1-64'
    GSA_FAKE_APP_INSTALLED=1
    stub_sudo "$ws"
    stub_makepkg "$ws"
    # Same toolchain-identity stamps as G: a missing stamp makes the
    # drift clean delete the pre-made archives before the build.
    mkdir -p "$ws/state/toolchains"
    gccline=$(LC_ALL=C gcc --version 2>/dev/null | head -1)
    [[ -n $gccline ]] || gccline='gcc unavailable'
    printf '%s\n%s\n' "$ws/packages/libs-git" "$gccline" >"$ws/state/toolchains/libs-git"
    printf '%s\n%s\n' "$ws/packages/app-git" "$gccline" >"$ws/state/toolchains/app-git"
    : >"$ws/pacman.log"
    : >"$ws/marker.snapshot"
    run_builder env \
        PATH="$ws/bin:$PATH" \
        GSA_STATE_DIR="$ws/state" \
        _IGNOREPKG_CONF="$ws/pacman.conf" \
        GSA_FAKE_PACMAN_LOG="$ws/pacman.log" \
        GSA_FAKE_QI_LIBS="$GSA_FAKE_QI_LIBS" \
        GSA_FAKE_QI_APP="$GSA_FAKE_QI_APP" \
        GSA_FAKE_APP_INSTALLED=1 \
        GSA_FAKE_ACCEPT_U=1 \
        GSA_FAKE_MARKER_SNAPSHOT="$ws/marker.snapshot" \
        GSA_CPU_THREADS=8 GSA_MEMORY_GIB=16 \
        fish "$ws/build-all.fish" --allow-broken-rustc --no-deps --no-sync -i libs-git app-git
    ((FIXTURE_RC == 0)) || fail "N: the in-run repair run must succeed: $FIXTURE_OUTPUT"
    n_log="$ws/state/logs/libs-git.log"
    [[ -f $n_log ]] || fail "N: no provider package log was written: $FIXTURE_OUTPUT"
    grep -Fq 'is scheduled for rebuild later in this run' "$n_log" ||
        fail "N: the repair note must render into the provider's log: $(cat "$n_log")"
    snap=$(cat "$ws/marker.snapshot")
    [[ $(grep -c '^U:' "$ws/marker.snapshot") -ge 2 ]] ||
        fail "N: expected at least two transactions (provider, then consumer): $snap"
    head -1 "$ws/marker.snapshot" | grep -Fq 'app-git' ||
        fail "N: the repair marker must be recorded BEFORE the provider's transaction lands: $snap"
    [[ ! -e "$ws/state/abi-repair/app-git" ]] ||
        fail "N: the consumer's install must consume its repair marker: $(ls "$ws/state/abi-repair")"
)
checks=$((checks + 4))

printf 'abi-drift-install fixture: PASS (%d checks)\n' "$checks"
