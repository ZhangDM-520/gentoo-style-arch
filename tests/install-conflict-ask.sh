#!/usr/bin/env bash
set -euo pipefail

# The install contract behind the stock→house swap (2026-10-04 hardening):
# the `-i`/`-ia` pipelines run ONE pacman transaction as
# `pacman -U --noconfirm --ask 4 …` — and `--ask 4` is load-bearing: bit
# (1 << 2) is ALPM_QUESTION_CONFLICT_PKG, so every "remove conflicting
# package?" prompt (the stock package standing where the -git build must go)
# is force-YESed instead of hanging a lane with no tty. Drop the mask and the
# swap silently stops happening; reorder or interleave other flags and the
# contract nobody can grep for breaks.
#
# Pinned here (stub oracle: every pacman argv lands in GSA_FAKE_PACMAN_LOG):
#   A. the `-i` transaction is exactly `pacman -U --noconfirm --ask 4 <archive>`
#      — no extra flags before, between or after;
#   B. `-ia --overwrite '*'` forwards the extra args AFTER those flags in the
#      SAME command (`-U --noconfirm --ask 4 --overwrite * <archives>`), so
#      they can never displace the conflict mask;
#   C. plan refusal rows (--install-decide: empty lists, PGO-instrumented
#      payloads) never reach the pacman stub — the auto-YES must not fire for
#      a transaction that was refused;
#   D. semantic pin: /usr/include/alpm.h still declares
#      ALPM_QUESTION_CONFLICT_PKG = (1 << 2). If the enum ever reorders, this
#      fails and forces re-deriving the mask (skipped, loudly, when alpm.h is
#      absent on a host).

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-install-conflict-ask.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    printf 'install conflict-ask fixture: %s\n' "$1" >&2
    exit 1
}

# make_case_workspace DIR — synthetic workspace + PATH stubs: trivial makepkg
# (archive per gsa_meta_any), passthrough sudo, argv-logging pacman (-Qp
# answers nothing: doubt installs, so the -i transaction always runs) and a
# pacman-conf DBPath oracle so preflight never probes the host's real
# /var/lib/pacman (check_pacman_db_health can REMOVE entries there).
make_case_workspace() {
    local dir=$1
    make_workspace "$dir" 1 2 low
    # Dynamic IgnorePkg registration target — per-case, never the host's
    # /etc/pacman.conf (the battery must be non-mutating).
    make_install_conf "$dir/pacman.conf"
    add_package "$dir" p1 "$gsa_meta_any"
    stub_makepkg "$dir"
    stub_sudo "$dir"
    mkdir -p "$dir/db/local"

    cat >"$dir/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'pacman %s\n' "$*" >>"${GSA_FAKE_PACMAN_LOG:?}"
case ${1:-} in
-Qp) exit 1 ;;
esac
exit 0
EOF
    chmod +x "$dir/bin/pacman"

    cat >"$dir/bin/pacman-conf" <<'EOF'
#!/usr/bin/env bash
set -u
if [[ ${1:-} == DBPath ]]; then
    printf '%s\n' "${GSA_FAKE_DB_PATH:?}"
    exit 0
fi
exit 1
EOF
    chmod +x "$dir/bin/pacman-conf"
}

# run_install DIR ARG... — builder run through the helper's capture with the
# fixture stubs on PATH. Status in FIXTURE_RC.
run_install() {
    local dir=$1
    shift
    run_builder env \
        PATH="$dir/bin:$PATH" \
        GSA_STATE_DIR="$dir/state" \
        _IGNOREPKG_CONF="$dir/pacman.conf" \
        GSA_FAKE_PACMAN_LOG="$dir/pacman.log" \
        GSA_FAKE_DB_PATH="$dir/db" \
        GSA_CPU_THREADS=8 \
        GSA_MEMORY_GIB=16 \
        fish "$dir/build-all.fish" --allow-broken-rustc --no-deps --no-sync "$@"
    return "$FIXTURE_RC"
}

# u_line DIR — the ONE `pacman -U` transaction line (none/multiple fail).
u_line() {
    local lines
    lines=$(grep '^pacman -U ' "$1/pacman.log" 2>/dev/null || true)
    [[ $(grep -c '^pacman -U ' "$1/pacman.log" 2>/dev/null || true) == 1 ]] ||
        fail "expected exactly one pacman -U transaction, log was: $(cat "$1/pacman.log" 2>/dev/null)"
    printf '%s\n' "$lines"
}

# ─── A. the -i transaction carries exactly -U --noconfirm --ask 4 ───────────
dir_a="$fixture/case-a"
make_case_workspace "$dir_a"
: >"$dir_a/pacman.log"
if ! run_install "$dir_a" -i p1; then
    fail "A: -i run failed (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
fi
u=$(u_line "$dir_a")
grep -Eq '^pacman -U --noconfirm --ask 4 /[^ ]*p1-1\.0\.0-1-any\.pkg\.tar\.zst$' <<<"$u" ||
    fail "A: the -i transaction must be exactly 'pacman -U --noconfirm --ask 4 <archive>' — the --ask 4 mask IS the stock-conflict removal contract — got: $u"
printf 'A: -i transaction flags pinned OK\n'

# ─── B. -ia extra args ride after the flags, same command ───────────────────
dir_b="$fixture/case-b"
make_case_workspace "$dir_b"
: >"$dir_b/packages/p1/p1-1.0.0-1-any.pkg.tar.zst"
: >"$dir_b/pacman.log"
if ! run_install "$dir_b" -ia --overwrite '*'; then
    fail "B: -ia --overwrite run failed (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
fi
u=$(u_line "$dir_b")
grep -Eq '^pacman -U --noconfirm --ask 4 --overwrite \* /[^ ]*p1-1\.0\.0-1-any\.pkg\.tar\.zst$' <<<"$u" ||
    fail "B: -ia's forwarded args must follow '-U --noconfirm --ask 4' in the SAME command, got: $u"
printf 'B: -ia --overwrite forwarding pinned OK\n'

# ─── C. refusal rows never reach the pacman stub ────────────────────────────
# The --install-decide seam prints the plan verbatim without executing; the
# executor (install_execute) aborts on any refusal row BEFORE the transaction.
# Either way a refused plan must leave the pacman (and sudo) stubs untouched —
# the --ask 4 auto-YES must never fire for a transaction that was refused.
dir_c="$fixture/case-c"
make_case_workspace "$dir_c"
add_package "$dir_c" p2 'pkgver=1.0.0
pkgrel=1
arch=(any)
build() {
  CFLAGS+=" -fprofile-generate"
}'

# C1: checked mode with nothing to install → `refuse empty-list` row, no
# execution, no pacman. (Rows are tab-framed — the plan_row codec; a fixture
# expectation must frame them identically or it pins the OLD grammar.)
: >"$dir_c/pacman.log"
rm -f "$dir_c/sudo.log"
DECIDE_RC=0
DECIDE_OUT=$(env PATH="$dir_c/bin:$PATH" \
    GSA_FAKE_PACMAN_LOG="$dir_c/pacman.log" \
    GSA_FAKE_DB_PATH="$dir_c/db" \
    _IGNOREPKG_CONF="$dir_c/pacman.conf" \
    fish "$dir_c/build-all.fish" --install-decide checked 2>"$dir_c/decide.err") || DECIDE_RC=$?
[[ $DECIDE_RC == 1 && $DECIDE_OUT == $'refuse\tempty-list' ]] ||
    fail "C1: seam must print 'refuse<TAB>empty-list' and rc 1, got rc=$DECIDE_RC out=$DECIDE_OUT"
[[ ! -s "$dir_c/pacman.log" ]] ||
    fail "C1: a refusal row reached the pacman stub: $(cat "$dir_c/pacman.log")"
printf 'C1: empty-list refusal never reaches pacman OK\n'

# C2/C3: a PGO-instrumented payload → pgo refusal rows. C2 pins the seam's
# rows; C3 runs the real -ia executor over the same archive and pins that the
# refusal aborts before any pacman invocation.
stage=$(mktemp -d "$fixture/stage.XXXXXX")
mkdir -p "$stage/usr/bin"
printf 'code\0/home/someone/build/pgo-fixture/src/A.dir/b.cxx.gcda\0code\n' \
    >"$stage/usr/bin/p2"
tar --zstd -cf "$dir_c/packages/p2/p2-1.0.0-1-any.pkg.tar.zst" -C "$stage" .
rm -rf -- "$stage"
arch="$dir_c/packages/p2/p2-1.0.0-1-any.pkg.tar.zst"

: >"$dir_c/pacman.log"
rm -f "$dir_c/sudo.log"
DECIDE_RC=0
DECIDE_OUT=$(env PATH="$dir_c/bin:$PATH" \
    GSA_FAKE_PACMAN_LOG="$dir_c/pacman.log" \
    GSA_FAKE_DB_PATH="$dir_c/db" \
    _IGNOREPKG_CONF="$dir_c/pacman.conf" \
    fish "$dir_c/build-all.fish" --install-decide force "$arch" 2>"$dir_c/decide.err") || DECIDE_RC=$?
expected=$'refuse\tpgo-hit\t'"$arch"$'\t./usr/bin/p2\nrefuse\tpgo-instrumented\t'"$arch"
[[ $DECIDE_RC == 1 && $DECIDE_OUT == "$expected" ]] ||
    fail "C2: seam must print the pgo refusal rows (tab-framed) and rc 1.\nwant: $expected\ngot (rc=$DECIDE_RC): $DECIDE_OUT"
[[ ! -s "$dir_c/pacman.log" ]] ||
    fail "C2: a pgo refusal row reached the pacman stub: $(cat "$dir_c/pacman.log")"
printf 'C2: pgo refusal rows pinned OK\n'

: >"$dir_c/pacman.log"
rm -f "$dir_c/sudo.log"
if run_install "$dir_c" -ia; then
    fail "C3: -ia over a PGO-instrumented payload must fail: $FIXTURE_OUTPUT"
fi
grep -Fq 'libgcov would recreate its build tree' <<<"$FIXTURE_OUTPUT" ||
    fail "C3: the refusal must explain the consequence, got: $FIXTURE_OUTPUT"
[[ ! -s "$dir_c/pacman.log" ]] ||
    fail "C3: install_execute ran pacman despite a refusal row: $(cat "$dir_c/pacman.log")"
[[ ! -s "$dir_c/sudo.log" ]] ||
    fail "C3: a refused transaction escalated via sudo: $(cat "$dir_c/sudo.log")"
printf 'C3: executor aborts on refusal rows before pacman OK\n'

# ─── D. semantic pin: the mask bit is ALPM_QUESTION_CONFLICT_PKG ────────────
# --ask 4 answers YES to the (1 << 2) question, ALPM_QUESTION_CONFLICT_PKG.
# The mask is a bit position in alpm.h's question enum: if the enum ever
# reorders, `--ask 4` silently answers a DIFFERENT question and the swap
# hangs or half-happens — so the enum itself is the fixture's oracle.
alpm_hdr=/usr/include/alpm.h
if [[ -r $alpm_hdr ]]; then
    grep -Eq 'ALPM_QUESTION_CONFLICT_PKG[[:space:]]*=[[:space:]]*\(1 << 2\)' "$alpm_hdr" ||
        fail "D: $alpm_hdr no longer declares 'ALPM_QUESTION_CONFLICT_PKG = (1 << 2)' — re-derive the --ask mask before trusting the stock→house swap"
    printf 'D: alpm.h CONFLICT_PKG = (1 << 2) pin OK\n'
else
    printf 'D: skipped — %s absent on this host; the --ask 4 semantic pin could not be checked\n' "$alpm_hdr"
fi

# ─── E. a spaced archive path reaches pacman as ONE argv (R-F22) ────────────
# The executor half of the row-codec contract: install_execute must hand the
# WHOLE archive path to pacman as one argument. The old space-joined rows
# truncated at the first space and pacman got a nonexistent path, aborting
# the transaction. The workspace root carries the space so the discovered
# archive path does; the stub logs one argv per line, so a split path shows
# up as a truncated argv line and a lost remainder.
(
    dir_e="$fixture/case-e"
    ws="$dir_e/the ws"
    make_case_workspace "$ws"
    arch_e="$ws/packages/p1/p1-1.0.0-1-any.pkg.tar.zst"
    : >"$arch_e"
    cat >"$ws/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -u
{
    printf 'BEGIN\n'
    for a in "$@"; do printf 'argv:%s\n' "$a"; done
    printf 'END\n'
} >>"${GSA_FAKE_PACMAN_LOG:?}"
exit 0
EOF
    chmod +x "$ws/bin/pacman"
    : >"$ws/pacman.log"
    run_install "$ws" -ia
    ((FIXTURE_RC == 0)) ||
        fail "E: -ia over a spaced path must succeed, got rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
    [[ $(grep -cxF "argv:$arch_e" "$ws/pacman.log") == 1 ]] ||
        fail "E: pacman never received the full spaced path as one argv: $(cat "$ws/pacman.log")"
    if grep -qxF "argv:${arch_e%% *}" "$ws/pacman.log"; then
        fail "E: the archive path was truncated at the first space: $(cat "$ws/pacman.log")"
    fi
    printf 'E: spaced archive path reaches pacman intact OK\n'
)

printf 'install conflict-ask fixture: PASS\n'
