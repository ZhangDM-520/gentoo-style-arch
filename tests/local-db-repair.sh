#!/usr/bin/env bash
set -uo pipefail

# Local pacman database integrity probe — the 2026-09-24 vscodium-insiders
# incident: a window-close TERM killed `pacman -U` three seconds into its
# commit, leaving /var/lib/pacman/local/<pkg>/ containing only `mtree`.
# From then on every transaction failed pacman's MISLEADING
# `invalid or corrupted package` (blaming the innocent archive) and
# makepkg's .BUILDINFO query printed the raw `desc` open error during the
# package() phase. The entry was unusable in every direction (-U, -R, -Ql),
# so the builder probes for desc/files-less entries and reports them.
#
# Contract migration (2026-10-04, R-F1): this fixture used to pin idle
# AUTO-REMOVAL (provably idle → `rm -rf`, rc 0). The robustness audit showed
# that gate could delete LIVE pacman state — alpm clients outside the old
# process-name list (this host runs paru), the probe↔rm TOCTOU, and a
# Ctrl-C storm killing the probe children so an empty holder list gated
# deletion mid-commit — and the repo invariant is "a system pacman database
# lock is never deleted automatically". The probe is now REPORT-ONLY for
# lock AND local-db state: nothing is ever deleted, every broken entry is
# named with the operator repair command, and a present problem is rc 1.
# The assertions below pin the NEW never-delete/report-only semantics (the
# auto-delete pins were rewritten accordingly).
#
# Sub-tests (all against fixture directories — the host's real
# /var/lib/pacman/local is never read or written):
#   1. broken entry (mtree only) → KEPT + report naming the entry, the
#      interrupted-commit cause and the `sudo rm -rf` operator command;
#      rc 1 (was: removed + rc 0). A stub-proven-idle pass pins the IDLE
#      classification line deterministically.
#   2. broken entry + live transaction holder (a real process holding the
#      sibling db.lck inode open — the probe is name-independent) → kept,
#      holder pid/cmd reported, HELD status; rc 1.
#   3. healthy entry (desc+files) → never touched; the leftover broken entry
#      is STILL kept (was: idle-removed), rc 1.
#   4. desc present, files missing → also broken (both members are universal
#      on a healthy box: measured 1754/1754), kept and reported; rc 1.
#   5. empty/absent dir → rc 0, no broken-entry noise.
#   6. static: the --local-db-check seam exists and check_pacman_db_health is
#      wired at all three sites (the shared install preflight that serves
#      both -i's preflight and -ia's entry, the interrupt teardown, and
#      run_pacman_locked's failure path), and the probe contains no
#      deletion command at all.
#
# Lock isolation: the PATH-stub `find` is a fixture-side oracle for the
# open-handle scan (GSA_FAKE_FIND_SCAN_MODE), so host processes cannot make
# this fixture flap; the holder is a real same-user process holding the lock
# inode open. The builder gains NO GSA_* test knob — it honours exactly the
# seven variables --help lists; GSA_FAKE_* names are consumed by the stubs
# only.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-localdb-fixture.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    printf '%s\n' "$@" >&2
    exit 1
}

make_workspace "$fixture" auto auto xhigh
add_package "$fixture" p1

cat >"$fixture/bin/find" <<'EOF'
#!/usr/bin/env bash
# Open-handle scan oracle: the holder probe's inode-match stage (the find
# invocation carrying -samefile over /proc/*/fd dirs) is simulated by
# GSA_FAKE_FIND_SCAN_MODE; the fd-dir listing stage and every other find use
# fall through to the real find.
if [[ -n ${GSA_FAKE_FIND_SCAN_MODE:-} ]]; then
    for a in "$@"; do
        if [[ $a == -samefile ]]; then
            case $GSA_FAKE_FIND_SCAN_MODE in
                clean) exit 0 ;;
                kill) exit 130 ;;
                blind) printf "find: '/proc/1/fd': Permission denied\n" >&2; exit 0 ;;
            esac
        fi
    done
fi
exec /usr/bin/find "$@"
EOF
chmod +x "$fixture/bin/find"

run_check() { # $1 = local-dir, $2 = output-file, rest = extra env assignments
    local dir=$1 out=$2
    shift 2
    env PATH="$fixture/bin:$PATH" "$@" \
        fish "$fixture/build-all.fish" --local-db-check "$dir" >"$out" 2>&1
}

# ── 1. broken entry → KEPT + loud report + operator command ────────────────
echo "phase 1: broken entry (mtree only) is reported and never removed"
local_db="$fixture/var/pacman/local"
mkdir -p "$local_db/insiders-1.0-1"
: >"$local_db/insiders-1.0-1/mtree"
out1="$fixture/phase1.out"
run_check "$local_db" "$out1" GSA_FAKE_FIND_SCAN_MODE=clean ; rc=$?
[[ $rc -eq 1 ]] || fail "broken-entry check rc=$rc, want 1 (never cleared)" "$(cat "$out1")"
[[ -d $local_db/insiders-1.0-1 ]] ||
    fail "broken entry was DELETED — the probe must be report-only"
grep -qF 'insiders-1.0-1' "$out1" ||
    fail "report does not name the broken entry:" "$(cat "$out1")"
grep -q 'interrupted pacman -U commit' "$out1" ||
    fail "report does not explain the interrupted-commit cause" "$(cat "$out1")"
grep -q 'sudo rm -rf' "$out1" ||
    fail "report lacks the sudo rm -rf operator command:" "$(cat "$out1")"
grep -qE -- '-s -i|.-ia' "$out1" ||
    fail "report does not name the reinstall step (-s -i / -ia)" "$(cat "$out1")"
grep -q 'NEVER deletes local database entries' "$out1" ||
    fail "report does not state the never-delete contract:" "$(cat "$out1")"
grep -q 'status: IDLE' "$out1" ||
    fail "stub-proven-idle pass lacks the IDLE classification:" "$(cat "$out1")"

# ── 2. live holder → kept, reported, HELD status, rc 1 ─────────────────────
echo "phase 2: broken entry with a live transaction holder is classified HELD"
mkdir -p "$local_db/held-1.0-1"
: >"$local_db/held-1.0-1/mtree"
lock="$fixture/var/pacman/db.lck"
: >"$lock"
sleep 60 60<"$lock" &
holder=$!
out2="$fixture/phase2.out"
run_check "$local_db" "$out2" ; rc=$?
[[ $rc -eq 1 ]] || fail "busy broken check rc=$rc, want 1" "$(cat "$out2")"
[[ -e $local_db/held-1.0-1 ]] ||
    fail "broken entry was REMOVED while a holder was alive"
grep -q "holder pid=$holder" "$out2" ||
    fail "holder pid not reported:" "$(cat "$out2")"
grep -q 'cmd=.*sleep' "$out2" ||
    fail "holder cmdline not reported:" "$(cat "$out2")"
grep -q 'status: HELD' "$out2" ||
    fail "live holder was not classified HELD:" "$(cat "$out2")"
grep -q 'interrupted pacman -U commit' "$out2" ||
    fail "report does not identify the broken entries:" "$(cat "$out2")"
grep -q 'sudo rm -rf' "$out2" ||
    fail "no manual recovery instructions for a held database" "$(cat "$out2")"
command kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null
rm -f "$lock"

# ── 3. healthy entry is never touched; broken leftovers are kept ───────────
echo "phase 3: healthy entry survives; the broken leftovers are kept too"
mkdir -p "$local_db/healthy-1.0-1"
: >"$local_db/healthy-1.0-1/desc"
: >"$local_db/healthy-1.0-1/files"
out3="$fixture/phase3.out"
run_check "$local_db" "$out3" ; rc=$?
[[ $rc -eq 1 ]] || fail "mixed db probe rc=$rc, want 1 (a broken entry remains)" "$(cat "$out3")"
[[ -d $local_db/healthy-1.0-1 ]] ||
    fail "HEALTHY entry was touched/removed by the probe"
[[ -d $local_db/held-1.0-1 ]] ||
    fail "broken entry was DELETED once the holder left — the probe must never remove entries"

# ── 4. desc present, files missing → broken too, kept and reported ─────────
echo "phase 4: desc-without-files entry is broken, kept and reported"
mkdir -p "$local_db/nofiles-1.0-1"
: >"$local_db/nofiles-1.0-1/desc"
out4="$fixture/phase4.out"
run_check "$local_db" "$out4" GSA_FAKE_FIND_SCAN_MODE=clean ; rc=$?
[[ $rc -eq 1 ]] || fail "files-missing check rc=$rc, want 1" "$(cat "$out4")"
[[ -d $local_db/nofiles-1.0-1 ]] ||
    fail "desc-present/files-missing entry was DELETED — the probe must never remove entries"
grep -qF 'nofiles-1.0-1' "$out4" ||
    fail "report does not name the desc-without-files entry:" "$(cat "$out4")"

# ── 5. empty local dir → clean rc 0 ─────────────────────────────────────────
echo "phase 5: empty local dir is a clean no-op"
empty_db="$fixture/var/pacman/empty-local"
mkdir -p "$empty_db"
out5="$fixture/phase5.out"
run_check "$empty_db" "$out5" ; rc=$?
[[ $rc -eq 0 ]] || fail "empty local dir rc=$rc, want 0" "$(cat "$out5")"
grep -q 'BROKEN' "$out5" &&
    fail "empty local dir produced a BROKEN warning" "$(cat "$out5")"
run_check "$fixture/var/pacman/absent-local" "$out5" ; rc=$?
[[ $rc -eq 0 ]] || fail "absent local dir rc=$rc, want 0"

# ── 6. static wiring pins ───────────────────────────────────────────────────
echo "phase 6: seam + three call sites present"
grep -q -- '--local-db-check' "$fixture/build-all.fish" ||
    fail "--local-db-check seam missing from build-all.fish"
grep -q 'function check_pacman_db_health' "$fixture/build-all.fish" ||
    fail "check_pacman_db_health function missing"
# Three direct wires after the 2026-09-26 install_preflight consolidation:
# the shared install preflight (called by check_runtime_prereqs for -i and by
# install_all for -ia), the interrupt teardown, and run_pacman_locked's
# failure path. (Was four sites before -i's preflight and -ia's entry were
# merged into install_preflight.)
wires=$(grep -c 'check_pacman_db_health (pacman_db_local_path)' \
    "$fixture/build-all.fish")
[[ "$wires" -ge 3 ]] ||
    fail "check_pacman_db_health wired at $wires site(s), want >=3" \
        "(shared install preflight, interrupt teardown, run_pacman_locked)"
grep -q 'function pacman_db_local_path' "$fixture/build-all.fish" ||
    fail "pacman_db_local_path helper missing (DBPath seam)"
# The report-only contract: no deletion command may remain in the probe
# itself (the operator command is printed as TEXT by its report helper).
health_body=$(sed -n '/^function check_pacman_db_health/,/^function /p' \
    "$fixture/build-all.fish")
if grep -qE '(^|[[:space:]])rm -rf' <<<"$health_body"; then
    fail "check_pacman_db_health still deletes local-db entries"
fi

echo "local-db repair fixture: PASS"
