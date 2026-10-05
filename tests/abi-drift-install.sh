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
    *) exit 1 ;;
    esac
    ;;
-Q)
    if [[ ${args[1]:-} == app-git ]]; then
        [[ ${GSA_FAKE_APP_INSTALLED:-0} == 1 ]] && exit 0
    fi
    exit 1
    ;;
-Qp) exit 1 ;;
-U)
    printf 'UNEXPECTED pacman -U in a decide-only run\n' >&2
    exit 99
    ;;
esac
exit 0
EOF
chmod +x "$ws/bin/pacman"

# decide MODE [ARCHIVE...] — the seam. Stdout only (the rows) in
# FIXTURE_OUTPUT; stderr is kept apart so user fish-config noise can never
# disturb the row assertions (install-conflict-ask's convention).
decide() {
    set +e
    FIXTURE_OUTPUT=$(env \
        PATH="$ws/bin:$PATH" \
        GSA_STATE_DIR="$ws/state" \
        GSA_FAKE_PACMAN_LOG="$ws/pacman.log" \
        GSA_FAKE_QI_LIBS="$GSA_FAKE_QI_LIBS" \
        GSA_FAKE_QI_APP="$GSA_FAKE_QI_APP" \
        GSA_FAKE_APP_INSTALLED="$GSA_FAKE_APP_INSTALLED" \
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

printf 'abi-drift-install fixture: PASS (%d checks)\n' "$checks"
