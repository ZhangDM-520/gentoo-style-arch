#!/usr/bin/env bash
set -euo pipefail

# The run record — the machine block's contract.
#
# print_run_record emits one bounded block at the end of EVERY started run
# (success, failure, sudo-preflight refusal, interrupt): two stable markers,
# `key: value` plan scalars, and one `pkg status rc dur reason` row per
# package in topological order. The block is the data seam the battery
# asserts on; the human summary above it is rendering, pinned once in
# tests/dashboard.sh's prose section.
#
# Pinned here:
#   1. block shape — the markers exactly once each, `format: 1`, the plan
#      scalars (selection-source / order / lanes / normal-jobs / core-jobs /
#      intensity) and outcome/rc;
#   2. row grammar — one row per selected package, in `order:` sequence,
#      fields `pkg status rc dur reason`, rc/dur an integer or '-';
#   3. the status enum END TO END — every status print_run_record can emit is
#      produced by a scenario below: succeeded (ok), failed (build-failed),
#      deferred = the lane rc-99 anchoring amendment (anchoring-refused, the
#      rc visible in the row), blocked (waits-on-deferred), never-started
#      (dispatch-stopped / preflight-refused / interrupted-before-start) and
#      interrupted (interrupted-mid-build). The reasons the stub machinery
#      cannot force stay whitelist-checked only: lane-lost, log-unwritable,
#      never-ready, mutex-timeout (the builder pacman MUTEX wait timed out),
#      result-clear-failed (a named dispatch refusal when the run-scoped
#      result slot cannot be cleared) and the signal names signal-hup /
#      signal-int / signal-term — an externally signalled lane's honest rc
#      129/130/143 records the signal name as its row reason instead of
#      build-failed;
#   4. the continuation output of an INTERRUPTED run — summary + record +
#      resume suggestion naming the non-succeeded rows in order (the
#      interrupt path used to exit 130 silently, with nothing to resume by).
#
# Synthesis comes from tests/lib/fixture-lib.bash; the block parsing helpers
# (rr_extract / rr_scalar / rr_rows / rr_row / rr_remaining) live there too.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-run-record.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    printf 'run record fixture: %s\n' "$1" >&2
    exit 1
}

STATUSES='succeeded failed deferred blocked never-started interrupted'
REASONS='ok build-failed lane-lost log-unwritable anchoring-refused upstream-unverified waits-on-deferred never-ready dispatch-stopped preflight-refused interrupted-before-start interrupted-mid-build mutex-timeout signal-hup signal-int signal-term result-clear-failed'
seen_statuses=$fixture/seen-statuses
: >"$seen_statuses"

# Grammar + enum + whitelist over one saved output; observed statuses are
# accumulated for the coverage closure at the end.
check_rows() { # $1 = saved output file
    local out=$1 pkg status rc dur reason extra n
    n=0
    while read -r pkg status rc dur reason extra; do
        [[ -n $pkg ]] || continue
        n=$((n + 1))
        [[ -z ${extra:-} ]] ||
            fail "$out: row for $pkg carries a multi-word reason ('$reason $extra') — the reason is one kebab-case token"
        [[ " $STATUSES " == *" $status "* ]] ||
            fail "$out: row for $pkg has status '$status', not one of: $STATUSES"
        [[ " $REASONS " == *" $reason "* ]] ||
            fail "$out: row for $pkg has reason '$reason', not one of: $REASONS"
        [[ $rc == - || $rc =~ ^[0-9]+$ ]] ||
            fail "$out: row for $pkg has non-numeric rc '$rc'"
        [[ $dur == - || $dur =~ ^[0-9]+$ ]] ||
            fail "$out: row for $pkg has non-numeric dur '$dur'"
        printf '%s\n' "$status" >>"$seen_statuses"
    done < <(rr_rows <"$out")
    ((n > 0)) || fail "$out: the run record carries no package rows"
}

# The suggestion line's trailing payload is the resume set
# (continuation_args joins flags then packages), so the expected list must be
# the line's suffix.
assert_suggestion() { # $1 = saved output file, $2 = expected package list
    local out=$1 want=$2 line
    line=$(grep '^  build-all\.fish ' "$out" | head -1) ||
        fail "$out: no continuation suggestion in the output"
    [[ $line == *" $want" ]] ||
        fail "$out: suggestion does not end with '$want': $line"
    printf '%s\n' "$line"
}

# ─── Workspaces ─────────────────────────────────────────────────────────────

# Three independent packages, one lane, deterministic plan (lanes=1 jobs=2
# intensity=low → record: lanes 1, normal-jobs 2, core-jobs 2 under
# GSA_CPU_THREADS=8 / GSA_MEMORY_GIB=16).
make_case_workspace() { # $1 = dir
    local dir=$1 id
    make_workspace "$dir" 1 2 low
    for id in p1 p2 p3; do
        add_package "$dir" "$id" "$gsa_meta_any"
    done
    stub_makepkg "$dir"
    stub_sudo "$dir"
    stub_pacman "$dir"
}

run_case() { # $1 = dir, $2 = saved output name, rest = builder args
    local dir=$1 out=$2
    shift 2
    run_builder env \
        PATH="$dir/bin:$PATH" \
        GSA_STATE_DIR="$dir/state" \
        GSA_FAKE_PACMAN_LOG="$dir/pacman.log" \
        GSA_CPU_THREADS=8 \
        GSA_MEMORY_GIB=16 \
        fish "$dir/build-all.fish" "$@"
    printf '%s\n' "$FIXTURE_OUTPUT" >"$fixture/$out"
}

# ─── 1. Success: block shape, scalars, one row per package ──────────────────
ws=$fixture/ws-success
make_case_workspace "$ws"
run_case "$ws" s1.out --allow-broken-rustc --no-deps --no-sync --intensity low p1 p2 p3
[[ $FIXTURE_RC -eq 0 ]] || fail "the all-success run exited $FIXTURE_RC: $(cat "$fixture/s1.out")"

[[ $(grep -c '^--- run record begin ---$' "$fixture/s1.out") -eq 1 ]] ||
    fail "the block begin marker is not printed exactly once"
[[ $(grep -c '^--- run record end ---$' "$fixture/s1.out") -eq 1 ]] ||
    fail "the block end marker is not printed exactly once"
[[ $(rr_scalar format <"$fixture/s1.out") == 1 ]] ||
    fail "unexpected record format: $(rr_scalar format <"$fixture/s1.out")"
[[ $(rr_scalar selection-source <"$fixture/s1.out") == 'groups=- packages=p1,p2,p3 ranges=-' ]] ||
    fail "selection-source wrong: $(rr_scalar selection-source <"$fixture/s1.out")"
[[ $(rr_scalar order <"$fixture/s1.out") == 'p1 p2 p3' ]] ||
    fail "order wrong: $(rr_scalar order <"$fixture/s1.out")"
[[ $(rr_scalar lanes <"$fixture/s1.out") == 1 ]] ||
    fail "lanes scalar wrong: $(rr_scalar lanes <"$fixture/s1.out")"
[[ $(rr_scalar normal-jobs <"$fixture/s1.out") == 2 ]] ||
    fail "normal-jobs scalar wrong: $(rr_scalar normal-jobs <"$fixture/s1.out")"
[[ $(rr_scalar core-jobs <"$fixture/s1.out") == 2 ]] ||
    fail "core-jobs scalar wrong: $(rr_scalar core-jobs <"$fixture/s1.out")"
[[ $(rr_scalar intensity <"$fixture/s1.out") == low ]] ||
    fail "intensity scalar wrong: $(rr_scalar intensity <"$fixture/s1.out")"
[[ $(rr_scalar outcome <"$fixture/s1.out") == success ]] ||
    fail "outcome wrong: $(rr_scalar outcome <"$fixture/s1.out")"
[[ $(rr_scalar rc <"$fixture/s1.out") == 0 ]] ||
    fail "rc scalar wrong: $(rr_scalar rc <"$fixture/s1.out")"

rows1=$(rr_rows <"$fixture/s1.out")
[[ $(wc -l <<<"$rows1") -eq 3 ]] ||
    fail "expected 3 rows for 3 packages, got:
$rows1"
[[ $(awk '{print $1}' <<<"$rows1" | tr '\n' ' ') == 'p1 p2 p3 ' ]] ||
    fail "rows do not follow the order: scalar:
$rows1"
for id in p1 p2 p3; do
    [[ $(rr_row "$id" status <"$fixture/s1.out") == succeeded ]] ||
        fail "$id did not succeed: $(rr_row "$id" <"$fixture/s1.out")"
    [[ $(rr_row "$id" rc <"$fixture/s1.out") == 0 ]] ||
        fail "$id succeeded with rc $(rr_row "$id" rc <"$fixture/s1.out")"
    [[ $(rr_row "$id" reason <"$fixture/s1.out") == ok ]] ||
        fail "$id reason wrong: $(rr_row "$id" reason <"$fixture/s1.out")"
done
check_rows "$fixture/s1.out"

# ─── 2. Failure: rc preserved, never-started rows say why ───────────────────
ws=$fixture/ws-failure
make_case_workspace "$ws"
GSA_FAKE_FAIL_PACKAGE=p2 run_case "$ws" s2.out \
    --allow-broken-rustc --no-deps --no-sync --intensity low p1 p2 p3
[[ $FIXTURE_RC -ne 0 ]] || fail "the failing run exited 0"
[[ $(rr_scalar outcome <"$fixture/s2.out") == failed ]] ||
    fail "outcome wrong: $(rr_scalar outcome <"$fixture/s2.out")"
[[ $(rr_scalar rc <"$fixture/s2.out") == 1 ]] ||
    fail "rc scalar wrong: $(rr_scalar rc <"$fixture/s2.out")"
[[ $(rr_row p1 status <"$fixture/s2.out") == succeeded ]] ||
    fail "p1 row wrong: $(rr_row p1 <"$fixture/s2.out")"
[[ $(rr_row p2 status <"$fixture/s2.out") == failed ]] ||
    fail "p2 row wrong: $(rr_row p2 <"$fixture/s2.out")"
# The row's rc is the lane's own exit status, not a summary guess.
[[ $(rr_row p2 rc <"$fixture/s2.out") == 1 ]] ||
    fail "p2 row rc is $(rr_row p2 rc <"$fixture/s2.out"), want the makepkg status 1"
[[ $(rr_row p2 reason <"$fixture/s2.out") == build-failed ]] ||
    fail "p2 reason wrong: $(rr_row p2 reason <"$fixture/s2.out")"
[[ $(rr_row p3 status <"$fixture/s2.out") == never-started ]] ||
    fail "p3 row wrong: $(rr_row p3 <"$fixture/s2.out")"
[[ $(rr_row p3 reason <"$fixture/s2.out") == dispatch-stopped ]] ||
    fail "p3 reason wrong: $(rr_row p3 reason <"$fixture/s2.out")"
[[ $(rr_row p3 rc <"$fixture/s2.out") == - && $(rr_row p3 dur <"$fixture/s2.out") == - ]] ||
    fail "p3 never ran but carries rc/dur: $(rr_row p3 <"$fixture/s2.out")"
# The resume set is the failed package BEFORE the unattempted one — a failed
# package must rebuild before its dependents (2026-09-26).
[[ $(rr_remaining <"$fixture/s2.out" | tr '\n' ' ') == 'p2 p3 ' ]] ||
    fail "resume set wrong: $(rr_remaining <"$fixture/s2.out" | tr '\n' ' ')"
assert_suggestion "$fixture/s2.out" 'p2 p3' >/dev/null
check_rows "$fixture/s2.out"

# ─── 3. Preflight refusal: nothing dispatched, nothing started ──────────────
ws=$fixture/ws-preflight
make_case_workspace "$ws"
# A sudo that can never install: the -i preflight must refuse before dispatch.
cat >"$ws/bin/sudo" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$ws/bin/sudo"
run_case "$ws" s3.out --allow-broken-rustc --no-deps --no-sync --intensity low --install p1 p2 p3
[[ $FIXTURE_RC -ne 0 ]] || fail "the preflight-refused run exited 0"
[[ $(rr_scalar outcome <"$fixture/s3.out") == failed ]] ||
    fail "outcome wrong: $(rr_scalar outcome <"$fixture/s3.out")"
for id in p1 p2 p3; do
    [[ $(rr_row "$id" <"$fixture/s3.out") == "$id never-started - - preflight-refused" ]] ||
        fail "$id row wrong: $(rr_row "$id" <"$fixture/s3.out")"
done
[[ $(rr_remaining <"$fixture/s3.out" | wc -l) -eq 3 ]] ||
    fail "everything was refused, so everything must remain"
check_rows "$fixture/s3.out"

# ─── 4. Deferral (the rc-99 anchoring amendment) and its blocked dependent ──
command -v vercmp >/dev/null || fail 'vercmp is required (it ships with pacman)'
ws=$fixture/ws-defer
make_workspace "$ws" 1 2 low
mkdir -p "$ws/fake"
printf '2.0.0-1\n' >"$ws/fake/repo_version"
# a-stable: a stable recipe whose moved source gets NO official document (404)
# → anchor_sums_from_official refuses, the lane parks it with rc 99 and the
# record row must say `deferred 99 … anchoring-refused` — not a failed build.
# The sync/anchor flow keys on the physical packages/stable/ path (the same
# inline recipe+record layout tests/anchor-defer.sh uses).
mkdir -p "$ws/packages/stable/a-stable"
{
    printf 'pkgname=a-stable\n'
    printf 'pkgver=1.0.0\n'
    printf 'pkgrel=1\n'
    printf 'arch=(any)\n'
    printf 'source=("https://example.invalid/a-$pkgver.tar.gz")\n'
    printf "sha256sums=('0000000000000000000000000000000000000000000000000000000000000000')\n"
} >"$ws/packages/stable/a-stable/PKGBUILD"
printf 'a-stable|packages/stable/a-stable|stable|\n' >>"$ws/config/topology.conf"
# b-dep is parked when a-stable defers: its edge is the reason.
add_package "$ws" b-dep "$gsa_meta_any"
add_package "$ws" c-plain "$gsa_meta_any"
set_topology_record "$ws" b-dep git 'a-stable'

cat >"$ws/bin/pacman" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == -Si ]]; then
    printf 'Repository      : extra\nName            : %s\nVersion         : %s\n' \
        "$2" "$(cat "$GSA_FAKE_DIR/repo_version")"
    exit 0
fi
exit 0
EOF
chmod +x "$ws/bin/pacman"
cat >"$ws/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GSA_FAKE_DIR/curl_calls"
exit 22
EOF
chmod +x "$ws/bin/curl"
cat >"$ws/bin/updpkgsums" <<'EOF'
#!/usr/bin/env bash
printf 'called\n' >>"$GSA_FAKE_DIR/updpkgsums_calls"
exit 0
EOF
chmod +x "$ws/bin/updpkgsums"
cat >"$ws/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
id=$(basename "$PWD")
printf '%s\n' "$id" >>"$GSA_FAKE_DIR/makepkg_calls"
: >"$PWD/$id-1.0.0-1-any.pkg.tar.zst"
exit 0
EOF
chmod +x "$ws/bin/makepkg"
stub_sudo "$ws"

run_builder env \
    PATH="$ws/bin:$PATH" \
    GSA_STATE_DIR="$ws/state" \
    GSA_FAKE_DIR="$ws/fake" \
    GSA_FAKE_PACMAN_LOG="$ws/pacman.log" \
    GSA_CPU_THREADS=8 \
    GSA_MEMORY_GIB=16 \
    fish "$ws/build-all.fish" --allow-broken-rustc --no-deps \
    --intensity low a-stable b-dep c-plain
printf '%s\n' "$FIXTURE_OUTPUT" >"$fixture/s4.out"
[[ $FIXTURE_RC -ne 0 ]] || fail "the deferral run exited 0 although a recipe was parked"
[[ $(rr_row a-stable status <"$fixture/s4.out") == deferred ]] ||
    fail "a-stable row wrong: $(rr_row a-stable <"$fixture/s4.out")"
# The rc-99 _ANCHOR_DEFER_RC amendment is DATA in the row, not folklore.
[[ $(rr_row a-stable rc <"$fixture/s4.out") == 99 ]] ||
    fail "a-stable row rc is $(rr_row a-stable rc <"$fixture/s4.out"), want 99"
[[ $(rr_row a-stable reason <"$fixture/s4.out") == anchoring-refused ]] ||
    fail "a-stable reason wrong: $(rr_row a-stable reason <"$fixture/s4.out")"
[[ $(rr_row b-dep status <"$fixture/s4.out") == blocked ]] ||
    fail "b-dep row wrong: $(rr_row b-dep <"$fixture/s4.out")"
[[ $(rr_row b-dep reason <"$fixture/s4.out") == waits-on-deferred ]] ||
    fail "b-dep reason wrong: $(rr_row b-dep reason <"$fixture/s4.out")"
[[ $(rr_row b-dep rc <"$fixture/s4.out") == - ]] ||
    fail "b-dep never ran but carries rc: $(rr_row b-dep <"$fixture/s4.out")"
# The dispatch CONTINUED around the parked recipe: c-plain built.
[[ $(rr_row c-plain status <"$fixture/s4.out") == succeeded ]] ||
    fail "c-plain row wrong: $(rr_row c-plain <"$fixture/s4.out")"
[[ $(rr_remaining <"$fixture/s4.out" | tr '\n' ' ') == 'a-stable b-dep ' ]] ||
    fail "resume set wrong: $(rr_remaining <"$fixture/s4.out" | tr '\n' ' ')"
check_rows "$fixture/s4.out"

# ─── 5. Interrupt: record + continuation on the 130 path ────────────────────
ws=$fixture/ws-interrupt
make_case_workspace "$ws"
cat >"$ws/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
id=$(basename "$PWD")
# Event marker: the fixture waits for this file before signalling INT, so the
# interrupt deterministically lands mid-build instead of racing the
# pre-dispatch phase on wall-clock time.
: >"$(cd "$(dirname "$0")/.." && pwd)/makepkg-started"
printf 'fake makepkg %s\n' "$PWD"
sleep 3
: >"$PWD/$id-1.0.0-1-any.pkg.tar.zst"
exit 0
EOF
chmod +x "$ws/bin/makepkg"
set +e
env PATH="$ws/bin:$PATH" \
    GSA_STATE_DIR="$ws/state" \
    GSA_FAKE_PACMAN_LOG="$ws/pacman.log" \
    GSA_CPU_THREADS=8 \
    GSA_MEMORY_GIB=16 \
    _LANE_STOP_GRACE_S=2 \
    fish "$ws/build-all.fish" --allow-broken-rustc --no-deps --no-sync \
    --intensity low p1 p2 p3 >"$fixture/s5.out" 2>&1 &
builder_pid=$!
# Wait (bounded) for the first lane's makepkg to actually start before
# signalling — an event, not a wall-clock guess. Under battery parallelism the
# pre-dispatch phase outlasts any fixed sleep, and an interrupt that lands
# BEFORE dispatch is a different, equally correct outcome (all rows
# never-started / interrupted-before-start) pinned by signal-abort-lock.sh;
# this scenario exists to pin the MID-build half and must not flake into it.
for _ in $(seq 1 300); do
    [[ -e $ws/makepkg-started ]] && break
    sleep 0.1
done
[[ -e $ws/makepkg-started ]] \
    || fail "the fake makepkg never started, so the interrupt cannot be timed:
$(cat "$fixture/s5.out")"
kill -INT "$builder_pid"
wait "$builder_pid"
int_rc=$?
set -e
# This scenario signals INT (kill -INT above), and an interrupted run exits
# with the signal's own status (gsa_signal_exit_rc: HUP 129 / INT 130 /
# TERM 143) — so 130 below is INT's status, not a flat default; a TERM or
# HUP scenario would pin 143 or 129 instead (the signal sent here stays INT).
[[ $int_rc -eq 130 ]] ||
    fail "the interrupted run exited $int_rc, want 130:
$(cat "$fixture/s5.out")"
[[ $(rr_scalar outcome <"$fixture/s5.out") == interrupted ]] ||
    fail "outcome wrong: $(rr_scalar outcome <"$fixture/s5.out")"
[[ $(rr_scalar rc <"$fixture/s5.out") == 130 ]] ||
    fail "rc scalar wrong: $(rr_scalar rc <"$fixture/s5.out")"
# The package in flight is interrupted-mid-build; the rest were never
# dispatched — and both facts are in the record, not just in prose.
[[ $(rr_row p1 <"$fixture/s5.out") == 'p1 interrupted - - interrupted-mid-build' ]] ||
    fail "p1 row wrong: $(rr_row p1 <"$fixture/s5.out")"
for id in p2 p3; do
    [[ $(rr_row "$id" <"$fixture/s5.out") == "$id never-started - - interrupted-before-start" ]] ||
        fail "$id row wrong: $(rr_row "$id" <"$fixture/s5.out")"
done
# Continuation output on the interrupt path (the run used to exit 130 with no
# summary, no record and nothing to resume by): the suggestion carries the
# plan triple + the semantics flags the run used, and ends with the resume
# set in row order.
suggest=$(assert_suggestion "$fixture/s5.out" 'p1 p2 p3')
for flag in '--lanes 1' '--jobs 2' '--intensity low' --no-deps --no-sync --allow-broken-rustc; do
    [[ $suggest == *"$flag"* ]] ||
        fail "interrupted-run suggestion dropped '$flag': $suggest"
done
check_rows "$fixture/s5.out"

# ─── 6. Enum closure: the whitelist and full status coverage ────────────────
for out in "$fixture"/s*.out; do
    check_rows "$out"
done
for status in $STATUSES; do
    grep -qx "$status" "$seen_statuses" ||
        fail "status '$status' was never produced by any scenario — the enum pin is incomplete"
done

printf 'run record fixture: PASS (block, rows, enum incl. deferred=rc99, interrupt continuation)\n'
