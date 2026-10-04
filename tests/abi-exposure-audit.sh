#!/usr/bin/env bash
set -euo pipefail

# ABI-drift guard layer 5 — the exposure audit (build-all.fish
# audit_lint_abi_exposure, reachable through `--audit-lint abi-exposure` and
# rendered in `--audit`; report-only everywhere). For every workspace lib
# whose soname provides (committed .SRCINFO bare stems) differ from the
# installed stock equivalent (the installed database's answer for the
# suffix-stripped stock name), it reports the provider → exposed-consumer
# mapping: one row per drifted provide per installed consumer whose Depends On
# reaches the drift (the drifted soname name or the stock name), `-> none`
# when nothing installed depends on it. Pinned here (stubbed pacman — the
# fixture fabricates the installed database):
#
#   A. output shape: stock-only and house-only drift rows, each naming
#      provider → exposed consumer, with the exact drift spelled out;
#   B. no drift (stem sets equal) → `audit-lint abi-exposure: clean`;
#   C. no installed stock equivalent → `skipped`, not `clean`;
#   D. report-only: findings never change the rc, and `--audit` renders the
#      section.
#
# Scratch workspace under $TMPDIR only; the real pacman DB is never read.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/tests/lib/fixture-lib.bash"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-abi-exposure-audit.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    printf 'abi-exposure-audit fixture: %s\n' "$1" >&2
    exit 1
}

checks=0

ws="$tmp/ws"
make_workspace "$ws" 1 2 low
add_package "$ws" libs-git "$gsa_meta_any"
{
    printf 'pkgbase = libs-git\n'
    printf 'pkgname = libs-git\n'
    printf '\tprovides = libgreet.so\n'
    printf '\tprovides = libnew.so\n'
} >"$ws/packages/libs-git/.SRCINFO"

# The pacman stub: -Qi libs answers the installed stock equivalent's provides
# (GSA_FAKE_QI_STOCK, empty = not installed), the bare `pacman -Qi` full dump
# is the fabricated installed database whose Depends On fields define the
# exposed consumers.
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
    if [[ -z ${args[1]:-} ]]; then
        cat "${GSA_FAKE_DUMP:?}" 2>/dev/null
        exit 0
    fi
    if [[ ${args[1]} == libs && -n ${GSA_FAKE_QI_STOCK:-} ]]; then
        printf '%s\n' "$GSA_FAKE_QI_STOCK"
        exit 0
    fi
    exit 1
    ;;
esac
exit 1
EOF
chmod +x "$ws/bin/pacman"

run_lint() {
    run_builder env \
        PATH="$ws/bin:$PATH" \
        GSA_STATE_DIR="$ws/state" \
        GSA_FAKE_PACMAN_LOG="$ws/pacman.log" \
        GSA_FAKE_QI_STOCK="$GSA_FAKE_QI_STOCK" \
        GSA_FAKE_DUMP="$ws/dump.txt" \
        fish "$ws/build-all.fish" --audit-lint "$1"
}

# The fabricated installed database: one exposed consumer per drift direction,
# one exposed via the stock NAME, one unexposed bystander. Field order mirrors
# pacman -Qi (Name first, Depends On below it).
cat >"$ws/dump.txt" <<'EOF'
Name : oldapp
Version : 1-1
Depends On : libold.so=0-64

Name : newapp
Version : 1-1
Depends On : libnew.so

Name : stockfan
Version : 1-1
Depends On : libs>=0.5

Name : other
Version : 1-1
Depends On : glibc
EOF

# The installed stock surface: carries libgreet.so (still there) and
# libold.so (dropped by the workspace recipe). The house surface adds
# libnew.so. So: libold.so=0-64 is stock-only, libnew.so is house-only.
GSA_FAKE_QI_STOCK='Name : libs
Version : 1-1
Provides : libgreet.so=1-64  libold.so=0-64'

# ─── A. output shape: provider → exposed consumer rows ─────────────────────
run_lint abi-exposure
((FIXTURE_RC == 0)) ||
    fail "A: --audit-lint must stay report-only (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
expected="exposure: libs-git -> newapp: libs-git carries 'libnew.so' that stock libs does not
exposure: libs-git -> oldapp: stock libs carries 'libold.so=0-64' but libs-git drops it
exposure: libs-git -> stockfan: libs-git carries 'libnew.so' that stock libs does not
exposure: libs-git -> stockfan: stock libs carries 'libold.so=0-64' but libs-git drops it
audit-lint abi-exposure: 4 finding(s)"
[[ $FIXTURE_OUTPUT == "$expected" ]] ||
    fail "A: wrong exposure rows.
want:
$expected
got:
$FIXTURE_OUTPUT"
if grep -Fq ' -> other' <<<"$FIXTURE_OUTPUT"; then
    fail "A: an unexposed bystander must not be mapped: $FIXTURE_OUTPUT"
fi
checks=$((checks + 3))

# ─── B. no drift → clean ───────────────────────────────────────────────────
# House surface trimmed to the stock's stems (libgreet.so + libold.so); the
# stock's auto-versioned entries still normalize to the same bare stems, so
# nothing differs.
printf 'pkgbase = libs-git\npkgname = libs-git\n\tprovides = libgreet.so\n\tprovides = libold.so\n' \
    >"$ws/packages/libs-git/.SRCINFO"
run_lint abi-exposure
grep -Fq 'audit-lint abi-exposure: clean' <<<"$FIXTURE_OUTPUT" ||
    fail "B: an unchanged stem set must be clean: $FIXTURE_OUTPUT"
checks=$((checks + 1))

# ─── C. no installed stock equivalent → skipped ────────────────────────────
GSA_FAKE_QI_STOCK=''
run_lint abi-exposure
grep -Fq 'audit-lint abi-exposure: skipped' <<<"$FIXTURE_OUTPUT" ||
    fail "C: nothing installed to compare must report skipped: $FIXTURE_OUTPUT"
checks=$((checks + 1))

# ─── D. --audit renders the section; findings stay report-only ─────────────
GSA_FAKE_QI_STOCK='Name : libs
Version : 1-1
Provides : libgreet.so=1-64  libold.so=0-64'
printf 'pkgbase = libs-git\npkgname = libs-git\n\tprovides = libgreet.so\n\tprovides = libnew.so\n' \
    >"$ws/packages/libs-git/.SRCINFO"
run_builder env \
    PATH="$ws/bin:$PATH" \
    GSA_STATE_DIR="$ws/state" \
    GSA_FAKE_PACMAN_LOG="$ws/pacman.log" \
    GSA_FAKE_QI_STOCK="$GSA_FAKE_QI_STOCK" \
    GSA_FAKE_DUMP="$ws/dump.txt" \
    fish "$ws/build-all.fish" --audit
((FIXTURE_RC == 0)) ||
    fail "D: --audit must stay report-only while findings exist (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
grep -Fq 'ABI exposure (soname provides vs installed stock):' <<<"$FIXTURE_OUTPUT" ||
    fail "D: --audit must render the ABI exposure section: $FIXTURE_OUTPUT"
grep -Fq "exposure: libs-git -> oldapp: stock libs carries 'libold.so=0-64' but libs-git drops it" \
    <<<"$FIXTURE_OUTPUT" ||
    fail "D: --audit must carry the exposure rows: $FIXTURE_OUTPUT"
checks=$((checks + 3))

printf 'abi-exposure-audit fixture: PASS (%d checks)\n' "$checks"
