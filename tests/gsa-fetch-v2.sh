#!/usr/bin/env bash
set -euo pipefail

# tests/gsa-fetch-v2.sh — Phase-4 fetch-ahead of the NATIVE engine (`gsa`,
# docs/gsa-contract.md §B.4 `-Sw`, §B.8 `--prefetch-ahead`/`--no-prefetch`,
# §D.1 `--fetch-job`, docs/adr/0004-prefetch-advisory.md). Everything here
# is synthetic: `$TMPDIR` workspaces, a stub `makepkg` on PATH whose
# `--verifysource` half is the fetch oracle and whose other half is the
# build oracle — no network, no pacman call, no sudo, no host state.
# Expectations are DERIVED from the stub event log and the run records the
# runs produced (rule 25(j) / contract §L.3) — never from pinned counts.
#
# Pinned here (seven ( subshell ) sections, one per scenario; run one alone
# with GSA_FETCH_V2_ONLY=a…g):
#   a. fetch-ahead-while-compiling: an upcoming recipe's `--verifysource`
#      starts and ends while an earlier recipe is still compiling (stub
#      clocks), and the run's fate is unchanged.
#   b. flaky-host advisory: the first prefetch attempt fails and the retry
#      recovers (`ok retry-ok`, warning-class) — the run still exits 0, the
#      run-record row stays `succeeded ok`, `$STATE_DIR/prefetch.log` names
#      the failure, and the `prefetch-warnings: 1` scalar counts it (owner
#      decision 5: never rows, never a format bump).
#   c. window bound: `--prefetch-ahead 2` over a five-package chain — at
#      most 2 packages are ever fetched-but-not-started (reaching 2), and
#      the continuation mirrors `--prefetch-ahead 2`.
#   d. skipped packages are never prefetched: a pure-VCS recipe and a
#      local-source-only recipe produce ZERO `--verifysource` spawns (and
#      never re-spawn), while the plain-URL sibling fetches exactly once.
#   e. `gsa -Sw` verdict rows and record: `skipped vcs-only` for the
#      pure-VCS recipe, `ok` for the mixed and plain ones (the mixed recipe
#      IS prefetched in v1), plan rows `skip <reason>`/`fetch`, outcome rows
#      `succeeded` — plus the `--dry-run` plan (`never-started dry-run`,
#      continuation mirrors `--dry-run`, nothing fetched).
#   f. quarantine-retry (owner decision 4): a pinned-bad cached file is
#      renamed `<name>.gsa-bad-<ts>` and the one retry re-fetches — exactly
#      2 attempts, verdict `ok quarantined-retry-ok`, nothing left at the
#      final name.
#   g. operator surface: `gsa --help` names both fetch-ahead flags (§L.1)
#      and hides `--fetch-job`; `--no-prefetch` fetches nothing and prints
#      no `prefetch-warnings` scalar; the `--fetch-job` seam publishes its
#      typed result row (§D.1); pacman/sudo stub logs stay EMPTY everywhere.
#
# House conventions: `( subshell )` sections (each an isolated scenario with
# its own workspace), inline oracle stubs (§D.2), `fail()` prefixes, and
# tests/lib/rr-v2.bash's `format: 2` parser + run_engine with
# GSA_TEST_ENGINE=gsa.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"

fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-fetch-v2.XXXXXX")
trap '/usr/bin/sudo -n rm -rf -- "$fixture" 2>/dev/null || rm -rf -- "$fixture" 2>/dev/null || true' EXIT

fail() {
    printf '%s\n' "$1" >&2
    if [ -n "${2:-}" ] && [ -f "$2" ]; then
        sed 's/^/    /' "$2" >&2
    fi
    exit 1
}

# fail_out MESSAGE — fail with the captured engine output as the evidence.
fail_out() {
    printf '%s\n' "$1" >&2
    printf '%s\n' "$FIXTURE_OUTPUT" | sed 's/^/    /' >&2
    exit 1
}

# Section filter: GSA_FETCH_V2_ONLY=<a..g> runs exactly one section.
want() { [ -z "${GSA_FETCH_V2_ONLY:-}" ] || [ "${GSA_FETCH_V2_ONLY}" = "$1" ]; }

# ─── Stub-knob vocabulary (§D.2: declared here in the change that adds them) ─
rr2_stub_knob GSA_FAKE_FETCH_LOG "gsa-fetch-v2 makepkg stub: FETCH/BUILD event log with nanosecond clocks (plus its per-package attempt counters)"
rr2_stub_knob GSA_FAKE_FETCH_FLAKY "gsa-fetch-v2 makepkg stub: package whose first --verifysource attempt fails and whose retry succeeds"
rr2_stub_knob GSA_FAKE_FETCH_BADFILE "gsa-fetch-v2 makepkg stub: package whose first --verifysource reports 'bad.tar.gz ... FAILED' and whose retry succeeds"
# GSA_FAKE_SUDO_LOG (sudo stub: argv log) and GSA_FAKE_PACMAN_LOG (trivial
# pacman stub: argv log) are the shared vocabulary's knobs — declared there,
# used here.

# ─── The engine under test: scratch build only when GSA_TEST_GSA_BIN is not
# already set (the rr-v2.bash run_engine convention) ──────────────────────
if [ -z "${GSA_TEST_GSA_BIN:-}" ]; then
    cargo build --offline --quiet --target-dir "$fixture/cargo" -p gsa-cli \
        --manifest-path "$gsa_repo_root/Cargo.toml" \
        || fail "cannot build the gsa binary for the fixture"
    GSA_TEST_GSA_BIN="$fixture/cargo/debug/gsa"
fi
gsa_bin="$GSA_TEST_GSA_BIN"
[ -x "$gsa_bin" ] || fail "cargo did not produce $gsa_bin"
export GSA_TEST_ENGINE=gsa
export GSA_TEST_GSA_BIN="$gsa_bin"

# ─── Oracle stubs (inline: §D.2 keeps oracles in the fixture that gives them
# meaning) ──────────────────────────────────────────────────────────────────

# write_fetch_makepkg DIR — the makepkg oracle. `--verifysource` is the
# FETCH half (owner decision 2's only fetch engine): FETCH_START/FETCH_END
# event lines with nanosecond clocks into $GSA_FAKE_FETCH_LOG, the flaky and
# bad-file knobs scripting the two advisory paths, one attempt counter file
# per package beside the log. Everything else is the BUILD half: BUILD_START
# /BUILD_END clocks and a trivial archive.
write_fetch_makepkg() {
    cat >"$1/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
id=$(basename "$PWD")
log="${GSA_FAKE_FETCH_LOG:?}"
if [[ " $* " == *" --verifysource "* ]]; then
    n=$(cat "$log.count.$id" 2>/dev/null || echo 0)
    n=$((n + 1))
    printf '%s\n' "$n" >"$log.count.$id"
    printf 'FETCH_START %s %s\n' "$id" "$(date +%s%N)" >>"$log"
    if [[ ${GSA_FAKE_FETCH_FLAKY:-} == "$id" && $n -eq 1 ]]; then
        printf 'stub flake: attempt %s failed\n' "$n" >&2
        printf 'FETCH_END %s %s\n' "$id" "$(date +%s%N)" >>"$log"
        exit 1
    fi
    if [[ ${GSA_FAKE_FETCH_BADFILE:-} == "$id" && $n -eq 1 ]]; then
        printf '    bad.tar.gz ... FAILED\n' >&2
        printf 'FETCH_END %s %s\n' "$id" "$(date +%s%N)" >>"$log"
        exit 1
    fi
    printf 'FETCH_END %s %s\n' "$id" "$(date +%s%N)" >>"$log"
    exit 0
fi
printf 'BUILD_START %s %s\n' "$id" "$(date +%s%N)" >>"$log"
sleep "${GSA_FAKE_BUILD_SECONDS:-0}"
printf 'BUILD_END %s %s\n' "$id" "$(date +%s%N)" >>"$log"
: >"$PWD/$id-1.0.0-1-any.pkg.tar.zst"
exit 0
EOF
    chmod +x "$1/bin/makepkg"
}

# write_log_sudo DIR — the sudo passthrough stub with an argv log (a fetch
# run never escalates; the log is the evidence).
write_log_sudo() {
    cat >"$1/bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'sudo %s\n' "$*" >>"${GSA_FAKE_SUDO_LOG:?}"
args=()
for a in "$@"; do
    case $a in
    -n | -v | --preserve-env | --preserve-env=* | --) ;;
    *) args+=("$a") ;;
    esac
done
((${#args[@]})) || exit 0
exec "${args[@]}"
EOF
    chmod +x "$1/bin/sudo"
}

# write_log_pacman DIR — the pacman stub that only records (a fetch run
# never transacts; a build run here has no install step).
write_log_pacman() {
    cat >"$1/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'pacman %s\n' "$*" >>"${GSA_FAKE_PACMAN_LOG:?}"
exit 0
EOF
    chmod +x "$1/bin/pacman"
}

# fetch_ws DIR — one synthetic workspace with the three stubs on PATH, the
# shared source cache under the workspace (SRCDEST: env wins in the fetch
# engine's lookup) and zero retry delay (fixture speed; the policy under
# test is the ATTEMPT count and the advisory, not the sleep).
fetch_ws() {
    local ws=$1
    make_workspace "$ws" 1 1 low
    write_fetch_makepkg "$ws"
    write_log_sudo "$ws"
    write_log_pacman "$ws"
    mkdir -p "$ws/srcdest"
    export PATH="$ws/bin:$PATH"
    export SRCDEST="$ws/srcdest"
    export GSA_FAKE_FETCH_LOG="$ws/fetch.log"
    export GSA_FAKE_PACMAN_LOG="$ws/pacman.log"
    export GSA_FAKE_SUDO_LOG="$ws/sudo.log"
    export _GSA_FETCH_RETRY_S=0
}

# fetch_attempts PKG — how many `--verifysource` spawns the stub saw.
fetch_attempts() {
    awk -v id="$1" '$1 == "FETCH_START" && $2 == id { n++ } END { print n + 0 }' "$GSA_FAKE_FETCH_LOG"
}

# event_ts KIND PKG — the stub clock of one event (empty when absent).
event_ts() {
    awk -v kind="$1" -v id="$2" '$1 == kind && $2 == id { print $3; exit }' "$GSA_FAKE_FETCH_LOG"
}

# assert_no_transactions WHAT — fetch-ahead never transacts. The toolchain
# preflight's read-only `pacman -Q rust-git` probe runs on every build-family
# run (2026-10-14, the probe-gating decision) and is tolerated here; what must
# stay absent is any TRANSACTION or any other pacman call.
assert_no_transactions() {
    if grep < <(grep -v '^pacman -Q rust-git$' "$GSA_FAKE_PACMAN_LOG" 2>/dev/null) -q .; then
        fail "$1: the pacman stub logged a call beyond the rust-git probe:" "$GSA_FAKE_PACMAN_LOG"
    fi
    [ ! -s "$GSA_FAKE_SUDO_LOG" ] || fail "$1: the sudo stub log must stay empty:" "$GSA_FAKE_SUDO_LOG"
}

# assert_verdict_row PKG VERDICT REASON WHAT — one `-Sw` verdict row
# (`<pkg> <verdict> <dur> <reason…>`, §D.1's own vocabulary on stdout).
assert_verdict_row() {
    vgrep "$FIXTURE_OUTPUT" -Eq "^$1 $2 [0-9]+ $3$" \
        || fail "$4: want verdict row '$1 $2 <dur> $3' (§D.1), got:
$FIXTURE_OUTPUT"
}

# max_fetched_unstarted — the window-bound measurement (plan.md §2.1): the
# largest number of packages that were fetched (FETCH_END) and had not yet
# started compiling (BUILD_START) at any one instant, from the stub clocks.
max_fetched_unstarted() {
    awk '$1 == "FETCH_END" || $1 == "BUILD_START" { print $3, $1, $2 }' "$GSA_FAKE_FETCH_LOG" |
        sort -k1,1n | awk '
            $2 == "FETCH_END" && !($3 in open) { open[$3] = 1; n++ }
            $2 == "BUILD_START" && ($3 in open) { delete open[$3]; n-- }
            n > max { max = n }
            END { print max + 0 }'
}

if want a; then
    # ─── a. fetch-ahead-while-compiling (plan.md §2.1) ─────────────────────
    (
        set -euo pipefail
        ws="$fixture/a/ws"
        fetch_ws "$ws"
        add_package "$ws" p1 "$gsa_meta_any"$'\nsource=(https://example.invalid/p1-1.0.0.tar.gz)'
        add_package "$ws" p2 "$gsa_meta_any"$'\nsource=(https://example.invalid/p2-1.0.0.tar.gz)'
        set_topology_record "$ws" p2 git p1
        export GSA_FAKE_BUILD_SECONDS=2

        run_engine "$ws" -B --state-dir "$ws/state" p1
        [ "$FIXTURE_RC" = 0 ] || fail_out "a: fetch-ahead must not change the run's fate (rc $FIXTURE_RC):"

        b1=$(event_ts BUILD_START p1)
        e1=$(event_ts BUILD_END p1)
        f2=$(event_ts FETCH_START p2)
        { [ -n "$b1" ] && [ -n "$e1" ] && [ -n "$f2" ]; } \
            || fail "a: missing FETCH/BUILD clocks in the stub log:" "$GSA_FAKE_FETCH_LOG"
        [ "$b1" -lt "$f2" ] || fail "a: p2's fetch ($f2) must start while p1 compiles (build start $b1)" "$GSA_FAKE_FETCH_LOG"
        [ "$f2" -lt "$e1" ] || fail "a: p2's fetch ($f2) must start before p1's build ends ($e1)" "$GSA_FAKE_FETCH_LOG"
        [ "$(fetch_attempts p2)" = 1 ] || fail "a: p2 must fetch exactly once" "$GSA_FAKE_FETCH_LOG"

        [ "$(rr2_outcome p1 status <<<"$FIXTURE_OUTPUT")" = succeeded ] || fail_out "a: p1 row must succeed:"
        [ "$(rr2_outcome p2 status <<<"$FIXTURE_OUTPUT")" = succeeded ] || fail_out "a: p2 row must succeed:"
        [ "$(rr2_scalar rc <<<"$FIXTURE_OUTPUT")" = 0 ] || fail_out "a: the run succeeds (rc 0):"
        assert_no_transactions a
    )
fi

if want b; then
    # ─── b. flaky-host advisory (plan.md §3.1, owner decision 5) ───────────
    (
        set -euo pipefail
        ws="$fixture/b/ws"
        fetch_ws "$ws"
        add_package "$ws" p1 "$gsa_meta_any"$'\nsource=(https://example.invalid/p1-1.0.0.tar.gz)'
        add_package "$ws" p2 "$gsa_meta_any"$'\nsource=(https://example.invalid/p2-1.0.0.tar.gz)'
        set_topology_record "$ws" p2 git p1
        export GSA_FAKE_BUILD_SECONDS=2
        export GSA_FAKE_FETCH_FLAKY=p2

        run_engine "$ws" -B --state-dir "$ws/state" p1
        [ "$FIXTURE_RC" = 0 ] || fail_out "b: an advisory prefetch failure never gates the run (rc $FIXTURE_RC):"

        # The lane's own build succeeded — the run-record row is the build's.
        [ "$(rr2_outcome p2 status <<<"$FIXTURE_OUTPUT")" = succeeded ] || fail_out "b: p2's build row must succeed:"
        [ "$(rr2_outcome p2 reason <<<"$FIXTURE_OUTPUT")" = ok ] || fail_out "b: p2's build row keeps the build's reason, not the flake:"
        # The advisory: prose section + one warning + the scalar (never rows).
        vgrep "$FIXTURE_OUTPUT" -q 'Prefetch warnings (advisory — lanes retry at build time):' \
            || fail_out "b: the prose prefetch-warning section is missing:"
        vgrep "$FIXTURE_OUTPUT" -q '· p2 ok retry-ok' \
            || fail_out "b: want warning '· p2 ok retry-ok':"
        [ "$(rr2_scalar prefetch-warnings <<<"$FIXTURE_OUTPUT")" = 1 ] \
            || fail_out "b: want prefetch-warnings: 1 (owner decision 5):"
        grep -q 'gsa-fetch: p2: attempt 1 failed' "$ws/state/prefetch.log" \
            || fail "b: prefetch.log must name the failed attempt:" "$ws/state/prefetch.log"
        [ "$(fetch_attempts p2)" = 2 ] || fail "b: the flaky host costs exactly one retry" "$GSA_FAKE_FETCH_LOG"
        assert_no_transactions b
    )
fi

if want c; then
    # ─── c. window bound (plan.md §2.1/§2.3, owner decision 1) ────────────
    (
        set -euo pipefail
        ws="$fixture/c/ws"
        fetch_ws "$ws"
        for n in 1 2 3 4 5; do
            add_package "$ws" "p$n" "$gsa_meta_any"$'\nsource=(https://example.invalid/p'"$n"$'-1.0.0.tar.gz)'
        done
        for n in 2 3 4 5; do
            set_topology_record "$ws" "p$n" git "p$((n - 1))"
        done
        export GSA_FAKE_BUILD_SECONDS=2

        run_engine "$ws" -B --state-dir "$ws/state" --prefetch-ahead 2 p1
        [ "$FIXTURE_RC" = 0 ] || fail_out "c: the run must succeed (rc $FIXTURE_RC):"

        max=$(max_fetched_unstarted)
        [ "$max" -le 2 ] || fail "c: more than 2 fetched-but-unstarted packages at once (max $max)" "$GSA_FAKE_FETCH_LOG"
        [ "$max" = 2 ] || fail "c: the window must actually reach its bound of 2 (max $max)" "$GSA_FAKE_FETCH_LOG"

        cmd=$(rr2_continuation command <<<"$FIXTURE_OUTPUT")
        case $cmd in
        *"--prefetch-ahead 2"*) ;;
        *) fail "c: the continuation must mirror --prefetch-ahead 2 (got: $cmd)" ;;
        esac
        assert_no_transactions c
    )
fi

if want d; then
    # ─── d. skipped packages are never prefetched (owner decision 3) ──────
    (
        set -euo pipefail
        ws="$fixture/d/ws"
        fetch_ws "$ws"
        add_package "$ws" decoy "$gsa_meta_any"$'\nsource=(https://example.invalid/decoy-1.0.0.tar.gz)'
        add_package "$ws" p-plain "$gsa_meta_any"$'\nsource=(https://example.invalid/plain-1.0.0.tar.gz)'
        add_package "$ws" p-vcs "$gsa_meta_any"$'\nsource=(git+https://example.invalid/x.git)'
        add_package "$ws" p-local "$gsa_meta_any"$'\nsource=(fix.patch)'
        set_topology_record "$ws" p-plain git decoy
        set_topology_record "$ws" p-vcs git decoy
        set_topology_record "$ws" p-local git decoy
        export GSA_FAKE_BUILD_SECONDS=1

        run_engine "$ws" -B --state-dir "$ws/state" decoy
        [ "$FIXTURE_RC" = 0 ] || fail_out "d: the run must succeed (rc $FIXTURE_RC):"

        [ "$(fetch_attempts p-plain)" = 1 ] || fail "d: the plain-URL recipe must prefetch exactly once" "$GSA_FAKE_FETCH_LOG"
        [ "$(fetch_attempts p-vcs)" = 0 ] || fail "d: the pure-VCS recipe must never be prefetched" "$GSA_FAKE_FETCH_LOG"
        [ "$(fetch_attempts p-local)" = 0 ] || fail "d: the local-source-only recipe must never be prefetched" "$GSA_FAKE_FETCH_LOG"
        [ "$(fetch_attempts decoy)" = 0 ] || fail "d: a started recipe must never be prefetched (no fetch races a lane)" "$GSA_FAKE_FETCH_LOG"
        for p in decoy p-plain p-vcs p-local; do
            [ "$(rr2_outcome "$p" status <<<"$FIXTURE_OUTPUT")" = succeeded ] || fail_out "d: $p must build:"
        done
        assert_no_transactions d
    )
fi

if want e; then
    # ─── e. `gsa -Sw` verdict rows and record (§B.4/§D.1/§H) ──────────────
    (
        set -euo pipefail
        ws="$fixture/e/ws"
        fetch_ws "$ws"
        add_package "$ws" p-vcs "$gsa_meta_any"$'\nsource=(git+https://example.invalid/x.git)'
        add_package "$ws" p-mixed "$gsa_meta_any"$'\nsource=(https://example.invalid/mixed-1.0.0.tar.gz git+https://example.invalid/y.git)'
        add_package "$ws" p-plain "$gsa_meta_any"$'\nsource=(https://example.invalid/plain-1.0.0.tar.gz)'

        run_engine "$ws" -Sw p-plain p-mixed p-vcs
        [ "$FIXTURE_RC" = 0 ] || fail_out "e: the fetch run must succeed (rc $FIXTURE_RC):"

        # Verdict rows: own vocabulary on stdout (§D.1).
        assert_verdict_row p-vcs skipped vcs-only e
        assert_verdict_row p-mixed ok ok e
        assert_verdict_row p-plain ok ok e
        # The §H record renders the same outcomes (expectations derived from
        # the rows above, rule 25(j)).
        [ "$(rr2_plan p-vcs plan <<<"$FIXTURE_OUTPUT")" = skip ] || fail_out "e: p-vcs plan row must be skip:"
        [ "$(rr2_plan p-vcs reason <<<"$FIXTURE_OUTPUT")" = vcs-only ] || fail_out "e: p-vcs plan reason must be vcs-only:"
        [ "$(rr2_plan p-mixed plan <<<"$FIXTURE_OUTPUT")" = fetch ] || fail_out "e: p-mixed plan row must be fetch (mixed recipes fetch in v1):"
        [ "$(rr2_outcome p-vcs status <<<"$FIXTURE_OUTPUT")" = succeeded ] || fail_out "e: a skipped fetch is succeeded (remaining: never re-fetches it):"
        [ "$(rr2_outcome p-vcs rc <<<"$FIXTURE_OUTPUT")" = - ] || fail_out "e: a skipped fetch produced no process code:"
        [ "$(rr2_outcome p-vcs reason <<<"$FIXTURE_OUTPUT")" = vcs-only ] || fail_out "e: the skip reason survives into the row:"
        [ "$(rr2_outcome p-mixed status <<<"$FIXTURE_OUTPUT")" = succeeded ] || fail_out "e: p-mixed row must succeed:"
        [ "$(rr2_scalar outcome <<<"$FIXTURE_OUTPUT")" = success ] || fail_out "e: run outcome is success:"
        [ "$(rr2_scalar rc <<<"$FIXTURE_OUTPUT")" = 0 ] || fail_out "e: rc follows §G.1 from the rows:"
        # Only the candidates touched makepkg.
        [ "$(fetch_attempts p-mixed)" = 1 ] || fail "e: p-mixed must fetch exactly once" "$GSA_FAKE_FETCH_LOG"
        [ "$(fetch_attempts p-plain)" = 1 ] || fail "e: p-plain must fetch exactly once" "$GSA_FAKE_FETCH_LOG"
        [ "$(fetch_attempts p-vcs)" = 0 ] || fail "e: p-vcs must never fetch" "$GSA_FAKE_FETCH_LOG"

        # `--dry-run` (§B.8): plan rows, `never-started dry-run`, nothing fetched.
        run_engine "$ws" -Sw --dry-run p-plain p-mixed p-vcs
        [ "$FIXTURE_RC" = 0 ] || fail_out "e: the dry run must succeed (rc $FIXTURE_RC):"
        [ "$(rr2_scalar outcome <<<"$FIXTURE_OUTPUT")" = planned ] || fail_out "e: a dry run's outcome is planned:"
        [ "$(rr2_outcome p-plain status <<<"$FIXTURE_OUTPUT")" = never-started ] || fail_out "e: dry-run rows are never-started:"
        [ "$(rr2_outcome p-plain reason <<<"$FIXTURE_OUTPUT")" = dry-run ] || fail_out "e: dry-run reason key:"
        [ "$(fetch_attempts p-plain)" = 1 ] || fail "e: --dry-run must not fetch" "$GSA_FAKE_FETCH_LOG"
        case $(rr2_continuation command <<<"$FIXTURE_OUTPUT") in
        *"gsa -Sw --dry-run"*) ;;
        *) fail "e: the continuation must mirror --dry-run" ;;
        esac
        assert_no_transactions e
    )
fi

if want f; then
    # ─── f. quarantine-retry (owner decision 4) ────────────────────────────
    (
        set -euo pipefail
        ws="$fixture/f/ws"
        fetch_ws "$ws"
        add_package "$ws" p-q "$gsa_meta_any"$'\nsource=(https://example.invalid/bad.tar.gz)'
        # The wall class: a pinned-bad file sitting in the shared cache.
        printf 'not what the recipe pins\n' >"$SRCDEST/bad.tar.gz"
        export GSA_FAKE_FETCH_BADFILE=p-q

        run_engine "$ws" -Sw p-q
        [ "$FIXTURE_RC" = 0 ] || fail_out "f: the fetch run must succeed after quarantine+retry (rc $FIXTURE_RC):"

        assert_verdict_row p-q ok quarantined-retry-ok f
        # Diagnostic: keep the pipeline but capture its rc, so a red names the
        # class (1 = content missing, 141 = SIGPIPE, 126/127 = spawn failure).
        greprc=0
        vgrep "$FIXTURE_OUTPUT" -q 'quarantined-retry-ok' || greprc=$?
        [ "$greprc" = 0 ] \
            || fail_out "f: the quarantine must be loud (warning line) — pipeline rc $greprc:"
        [ "$(fetch_attempts p-q)" = 2 ] || fail "f: exactly 2 attempts (quarantine, then the one retry)" "$GSA_FAKE_FETCH_LOG"
        # A bad file is never left at its final name (plan.md §3.5).
        [ ! -e "$SRCDEST/bad.tar.gz" ] || fail "f: bad.tar.gz must not survive at its final name" "$SRCDEST"
        ls -la "$SRCDEST" >"$fixture/f.srcdest.txt" 2>&1 || true
        ls "$SRCDEST"/bad.tar.gz.gsa-bad-* >/dev/null 2>&1 \
            || fail "f: want a quarantined rename bad.tar.gz.gsa-bad-<ts>:" "$fixture/f.srcdest.txt"
        assert_no_transactions f
    )
fi

if want g; then
    # ─── g. operator surface (§L.1), --no-prefetch, the --fetch-job seam ──
    (
        set -euo pipefail
        ws="$fixture/g/ws"
        fetch_ws "$ws"
        add_package "$ws" p1 "$gsa_meta_any"$'\nsource=(https://example.invalid/p1-1.0.0.tar.gz)'
        add_package "$ws" p2 "$gsa_meta_any"$'\nsource=(https://example.invalid/p2-1.0.0.tar.gz)'
        set_topology_record "$ws" p2 git p1
        export GSA_FAKE_BUILD_SECONDS=1

        run_engine "$ws" --help
        [ "$FIXTURE_RC" = 0 ] || fail_out "g: --help must succeed"
        vgrep "$FIXTURE_OUTPUT" -q -- '--no-prefetch' || fail_out "g: --help must name --no-prefetch (§L.1)"
        vgrep "$FIXTURE_OUTPUT" -q -- '--prefetch-ahead' || fail_out "g: --help must name --prefetch-ahead (§L.1)"
        vgrep "$FIXTURE_OUTPUT" -q -- '--fetch-job' && fail_out "g: --help must hide --fetch-job (§D.1)"

        # --no-prefetch: zero fetch spawns, no scalar (owner decision 5).
        run_engine "$ws" -B --state-dir "$ws/state" --no-prefetch p1
        [ "$FIXTURE_RC" = 0 ] || fail_out "g: --no-prefetch run must succeed (rc $FIXTURE_RC):"
        [ "$(fetch_attempts p1)" = 0 ] && [ "$(fetch_attempts p2)" = 0 ] \
            || fail "g: --no-prefetch must spawn zero fetch children" "$GSA_FAKE_FETCH_LOG"
        vgrep "$FIXTURE_OUTPUT" -q '^prefetch-warnings: ' \
            && fail_out "g: --no-prefetch runs print no prefetch-warnings scalar:"

        # The --fetch-job seam (§D.1): one recipe, one typed result row.
        run_engine "$ws" --fetch-job p1 "$ws/p1.fetch.result"
        [ "$FIXTURE_RC" = 0 ] || fail_out "g: --fetch-job must exit 0 (failed is data, not process failure)"
        grep -Eq '^v2 p1 ok [0-9]+ ok$' "$ws/p1.fetch.result" \
            || fail "g: want a typed 'v2 p1 ok <dur> ok' result row:" "$ws/p1.fetch.result"
        assert_no_transactions g
    )
fi

printf 'gsa-fetch-v2: ok\n'
