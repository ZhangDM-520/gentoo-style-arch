#!/usr/bin/env bash
# tests/lib/rr-v2.bash — v2 fixture library: the `format: 2` run-record parser,
# the engine runner, and the GSA_FAKE_* stub-knob vocabulary. SOURCED, never
# executed as a fixture. The same two conventions that keep fixture-lib.bash
# out of the battery keep this file out of it, and both are load-bearing (see
# tests/run-all.sh):
#   * the extension is .bash, not .sh — run-all.sh discovers fixtures with
#     `find . -name '*.sh'`, so this file can never be picked up as one;
#   * run-all.sh additionally excludes ./lib/* — defence in depth.
#
# Source it from a fixture (repo root resolves from THIS file's BASH_SOURCE):
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"
#
# SCOPE: the v2 successor of tests/lib/fixture-lib.bash's run-record parser and
# stub-vocabulary role (docs/gsa-contract.md §D.2). The fish-era fixture
# synthesis helpers (make_workspace, add_package, stub_*, run_builder) and the
# `format: 1` rr_* parser stay in fixture-lib.bash until their fixtures flip
# per docs/gsa-fixture-migration.md; fixture-lib.bash itself must remain
# byte-identical during the staged migration (single-writer discipline).
#
# ─── What this file provides ────────────────────────────────────────────────
#   rr2_body            strict `format: 2` block validation + extraction
#   rr2_scalar KEY      one run-record scalar
#   rr2_plan_rows       plan-section rows (`pkg plan reason…`)
#   rr2_plan PKG [F]    one package's plan row / field (plan|reason)
#   rr2_outcome_rows    outcome-section rows (`pkg status rc dur reason…`)
#   rr2_outcome PKG [F] one package's outcome row / field (status|rc|dur|reason)
#   rr2_continuation [K] continuation lines, or one key's value
#   rr2_remaining       resume set derived from the outcome rows (status !=
#                       succeeded, in row order) — the §H.2 `remaining:` rule
#   run_engine          invoke the current engine (fish builder today, gsa at
#                       cutover) and capture FIXTURE_OUTPUT / FIXTURE_RC
#   rr2_stub_knob       declare one GSA_FAKE_* stub knob (§D.2)
#   rr2_stub_knobs      print the declared vocabulary (name<TAB>description)
#
# All rr2_* accessors read stdin (like their rr_* predecessors) and expect the
# RAW stream — the captured run output containing exactly one block, markers
# included (rr2_body does the extraction; an already-extracted body has no
# markers and is loudly rejected) — so both `<<<"$output"` and `<"$file"` work;
# a trailing CR is stripped first so PTY captures parse like pipe output.

# ─── format: 2 grammar — docs/gsa-contract.md §H.2 ──────────────────────────
# block   = "--- run record begin ---" NL *scalar
#           "--- plan ---" NL *plan-row
#           "--- outcome ---" NL *outcome-row
#           "--- continuation ---" NL *continuation-line
#           "--- run record end ---" NL
# scalar  = key ":" SP value NL     ; fixed order: format, selection-source,
#                                   ; order, lanes, normal-jobs, core-jobs,
#                                   ; intensity, outcome, rc; extension
#                                   ; scalars append after the fixed set
# plan-row     = pkg SP plan SP reason… NL   ; plan ∈ {build, build-install,
#                                   ; install, fetch, skip, parked, refused,
#                                   ; noop}
# outcome-row  = pkg SP status SP rc SP dur SP reason… NL
#                                   ; status ∈ {succeeded, failed, deferred,
#                                   ; parked, never-started, interrupted}
#                                   ; rc/dur: integer or "-"
# continuation-line = key ":" SP value NL    ; key ∈ {command, remaining,
#                                   ; not-mirrored, env-required}
#
# STRICTNESS: the parser rejects malformed blocks loudly (reason on stderr,
# non-zero status) instead of letting a fixture fall back to prose. Rules the
# §H grammar states are enforced as written; where the contract is silent the
# parser takes the strict reading and docs/gsa-fixture-migration.md "Contract
# gaps found" records the silence: blank lines and control characters inside
# the block are rejected, duplicate scalars/rows/continuation keys are
# rejected, plan and outcome rows must agree with the `order` scalar
# (§C.5: one topological order everywhere), rc must be the row status's lane
# code or "-" (§H.3/§G.2), and `format` must be exactly `2` (a `format: 1`
# block is data for tests/lib/fixture-lib.bash's rr_*, not for these helpers).

rr2_body() {
    awk '
        function bad(msg) {
            printf("rr2_body: %s\n", msg) > "/dev/stderr"
            exit 1
        }
        { sub(/\r$/, ""); lines[++nl] = $0 }
        END {
            for (i = 1; i <= nl; i++) {
                if (lines[i] == "--- run record begin ---") {
                    if (inb) bad("nested run-record begin marker")
                    blocks++
                    if (blocks > 1) bad("expected exactly one run-record block, saw a second begin marker")
                    inb = 1
                    continue
                }
                if (lines[i] == "--- run record end ---") {
                    if (!inb) bad("run-record end marker outside a block")
                    inb = 0
                    continue
                }
                if (inb) body[++n] = lines[i]
            }
            if (blocks == 0) bad("no run-record block found")
            if (inb) bad("run-record block is not closed (missing end marker)")

            fix[1] = "format"; fix[2] = "selection-source"; fix[3] = "order"
            fix[4] = "lanes"; fix[5] = "normal-jobs"; fix[6] = "core-jobs"
            fix[7] = "intensity"; fix[8] = "outcome"; fix[9] = "rc"

            sec = 0
            for (i = 1; i <= n; i++) {
                ln = body[i]
                if (ln ~ /^--- /) {
                    if (ln == "--- plan ---") {
                        if (sec != 0) bad("plan section misplaced (it must follow the scalars)")
                        if (nfix != 9) bad("missing scalar " fix[nfix + 1])
                        sec = 1
                        continue
                    }
                    if (ln == "--- outcome ---") {
                        if (sec != 1) bad("outcome section must follow the plan section")
                        sec = 2
                        continue
                    }
                    if (ln == "--- continuation ---") {
                        if (sec != 2) bad("continuation section must follow the outcome section")
                        sec = 3
                        continue
                    }
                    bad("unexpected marker line in run record: " ln)
                }
                if (ln == "") bad("blank line inside the run-record block")
                if (ln ~ /[[:cntrl:]]/) bad("control character in run-record line: " ln)

                if (sec == 0) {
                    if (ln !~ /^[a-z0-9-]+:( .*)?$/) bad("malformed scalar line (want key: value): " ln)
                    p = index(ln, ":")
                    key = substr(ln, 1, p - 1)
                    val = substr(ln, p + 1)
                    sub(/^ /, "", val)
                    if (key in seen) bad("duplicate scalar " key)
                    seen[key] = 1
                    if (nfix < 9) {
                        nfix++
                        if (key != fix[nfix]) \
                            bad("fixed scalar order: want " fix[nfix] " next, got " key " (extension scalars come after the fixed set)")
                    }
                    if (key == "format" && val != "2") bad("unsupported format " val " (want 2)")
                    if (key == "lanes" || key == "normal-jobs" || key == "core-jobs" || key == "rc") {
                        if (val !~ /^[0-9]+$/) bad("scalar " key " must be a non-negative integer, got " val)
                    }
                    if (key == "order" && val != "") {
                        m = split(val, toks, " ")
                        for (j = 1; j <= m; j++) {
                            if (toks[j] !~ /^[A-Za-z0-9@._+-]+$/) \
                                bad("order scalar: malformed package id " toks[j])
                            if (toks[j] in seenord) bad("order scalar: duplicate package " toks[j])
                            seenord[toks[j]] = 1
                            ord[++nord] = toks[j]
                        }
                    }
                    continue
                }

                # pkg/field2/reason split on the first two single spaces
                p = index(ln, " ")
                pkg = substr(ln, 1, p - 1)
                rest = substr(ln, p + 1)
                q = index(rest, " ")
                field2 = (q ? substr(rest, 1, q - 1) : rest)
                reason = (q ? substr(rest, q + 1) : "")

                if (sec == 1) {
                    if (ln !~ /^[^ ]+ [^ ]+ [^ ]/) bad("malformed plan row (want pkg plan reason): " ln)
                    if (pkg !~ /^[A-Za-z0-9@._+-]+$/) bad("plan row: malformed package id " pkg)
                    if (!(field2 == "build" || field2 == "build-install" || field2 == "install" \
                          || field2 == "fetch" || field2 == "skip" || field2 == "parked" \
                          || field2 == "refused" || field2 == "noop")) \
                        bad("plan row " pkg ": unknown plan value " field2)
                    if (pkg in seenplan) bad("duplicate plan row for " pkg)
                    seenplan[pkg] = 1
                    nplan++
                    if (nplan > nord) bad("plan row " pkg ": no order scalar position " nplan)
                    if (ord[nplan] != pkg) \
                        bad("plan row " nplan ": package " pkg " does not match order scalar position " nplan " (" ord[nplan] ")")
                    continue
                }

                if (sec == 2) {
                    if (ln !~ /^[^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]/) \
                        bad("malformed outcome row (want pkg status rc dur reason): " ln)
                    split(ln, f, " ")
                    pkg = f[1]; status = f[2]; rc = f[3]; dur = f[4]
                    if (pkg !~ /^[A-Za-z0-9@._+-]+$/) bad("outcome row: malformed package id " pkg)
                    if (!(status == "succeeded" || status == "failed" || status == "deferred" \
                          || status == "parked" || status == "never-started" || status == "interrupted")) \
                        bad("outcome row " pkg ": unknown outcome status " status)
                    if (rc != "-" && rc !~ /^[0-9]+$/) \
                        bad("outcome row " pkg ": rc " rc " is not an integer or -")
                    if (dur != "-" && dur !~ /^[0-9]+$/) \
                        bad("outcome row " pkg ": dur " dur " is not an integer or -")
                    if (rc != "-") {
                        ok = 0
                        if (status == "succeeded" && rc == "0") ok = 1
                        if (status == "failed" && (rc == "1" || rc == "125")) ok = 1
                        if (status == "deferred" && rc == "99") ok = 1
                        if (status == "parked" && rc == "98") ok = 1
                        if (status == "interrupted" && (rc == "129" || rc == "130" || rc == "143")) ok = 1
                        if (!ok) \
                            bad("outcome row " pkg ": rc " rc " is not a lane code for status " status)
                    }
                    if (pkg in seenout) bad("duplicate outcome row for " pkg)
                    seenout[pkg] = 1
                    nout++
                    if (nout > nord) bad("outcome row " pkg ": no order scalar position " nout)
                    if (ord[nout] != pkg) \
                        bad("outcome row " nout ": package " pkg " does not match order scalar position " nout " (" ord[nout] ")")
                    continue
                }

                # continuation
                if (ln !~ /^[a-z0-9-]+:( .*)?$/) bad("malformed continuation line (want key: value): " ln)
                p = index(ln, ":")
                key = substr(ln, 1, p - 1)
                val = substr(ln, p + 1)
                sub(/^ /, "", val)
                if (!(key == "command" || key == "remaining" || key == "not-mirrored" || key == "env-required")) \
                    bad("unknown continuation key " key)
                if (key in seencont) bad("duplicate continuation key " key)
                seencont[key] = 1
                if (key == "remaining" && val != "") {
                    m = split(val, toks, " ")
                    for (j = 1; j <= m; j++) {
                        if (toks[j] !~ /^[A-Za-z0-9@._+-]+$/) \
                            bad("remaining: malformed package id " toks[j])
                    }
                }
            }

            if (sec == 0) bad("missing section plan")
            if (sec == 1) bad("missing section outcome")
            if (sec == 2) bad("missing section continuation")

            for (i = 1; i <= n; i++) print body[i]
        }
    '
}

# rr2_scalar KEY — the value of one run-record scalar. Fails when the key is
# absent.
rr2_scalar() {
    local body
    body=$(rr2_body) || return 1
    printf '%s\n' "$body" | awk -v key="$1" '
        /^--- plan ---$/ { exit }
        {
            p = index($0, ":")
            if (p && substr($0, 1, p - 1) == key) {
                v = substr($0, p + 1)
                sub(/^ /, "", v)
                print v
                found = 1
                exit
            }
        }
        END {
            if (!found) {
                printf("rr2_scalar: no %s scalar in the run record\n", key) > "/dev/stderr"
                exit 1
            }
        }
    '
}

# rr2_plan_rows — the plan-section rows only (`pkg plan reason…`, topological
# order).
rr2_plan_rows() {
    local body
    body=$(rr2_body) || return 1
    printf '%s\n' "$body" | awk '
        /^--- plan ---$/ { p = 1; next }
        /^--- outcome ---$/ { exit }
        p { print }
    '
}

# rr2_plan PKG [plan|reason] — one package's plan row, or one of its fields.
# The reason is the remainder of the line. Fails when the package has no row.
rr2_plan() {
    local body rows
    body=$(rr2_body) || return 1
    rows=$(printf '%s\n' "$body" | awk '
        /^--- plan ---$/ { p = 1; next }
        /^--- outcome ---$/ { exit }
        p { print }
    ')
    printf '%s\n' "$rows" | awk -v pkg="$1" -v field="${2:-}" '
        $1 == pkg && !found {
            found = 1
            if (field == "") { print; next }
            if (field == "plan") { print $2; next }
            if (field == "reason") {
                for (i = 3; i <= NF; i++) printf("%s%s", (i > 3 ? " " : ""), $i)
                print ""
                next
            }
            bad = 1
        }
        END {
            if (!found) {
                printf("rr2_plan: package %s has no plan row\n", pkg) > "/dev/stderr"
                exit 1
            }
            if (bad) {
                printf("rr2_plan: unknown field %s (want plan|reason)\n", field) > "/dev/stderr"
                exit 1
            }
        }
    '
}

# rr2_outcome_rows — the outcome-section rows only (`pkg status rc dur
# reason…`, topological order).
rr2_outcome_rows() {
    local body
    body=$(rr2_body) || return 1
    printf '%s\n' "$body" | awk '
        /^--- outcome ---$/ { p = 1; next }
        /^--- continuation ---$/ { exit }
        p { print }
    '
}

# rr2_outcome PKG [status|rc|dur|reason] — one package's outcome row, or one
# of its fields. The reason is the remainder of the line. Fails when the
# package has no row.
rr2_outcome() {
    local body rows
    body=$(rr2_body) || return 1
    rows=$(printf '%s\n' "$body" | awk '
        /^--- outcome ---$/ { p = 1; next }
        /^--- continuation ---$/ { exit }
        p { print }
    ')
    printf '%s\n' "$rows" | awk -v pkg="$1" -v field="${2:-}" '
        $1 == pkg && !found {
            found = 1
            if (field == "") { print; next }
            if (field == "status") { print $2; next }
            if (field == "rc") { print $3; next }
            if (field == "dur") { print $4; next }
            if (field == "reason") {
                for (i = 5; i <= NF; i++) printf("%s%s", (i > 5 ? " " : ""), $i)
                print ""
                next
            }
            bad = 1
        }
        END {
            if (!found) {
                printf("rr2_outcome: package %s has no outcome row\n", pkg) > "/dev/stderr"
                exit 1
            }
            if (bad) {
                printf("rr2_outcome: unknown field %s (want status|rc|dur|reason)\n", field) > "/dev/stderr"
                exit 1
            }
        }
    '
}

# rr2_continuation [KEY] — the continuation lines as `key: value`, or one
# key's value (KEY without the trailing colon). Fails when the key is absent.
rr2_continuation() {
    local body
    body=$(rr2_body) || return 1
    printf '%s\n' "$body" | awk -v key="${1:-}" '
        /^--- continuation ---$/ { p = 1; next }
        p {
            if (key == "") { print; next }
            c = index($0, ":")
            if (c && substr($0, 1, c - 1) == key) {
                v = substr($0, c + 1)
                sub(/^ /, "", v)
                print v
                found = 1
                exit
            }
        }
        END {
            if (key != "" && !found) {
                printf("rr2_continuation: no %s line in the continuation\n", key) > "/dev/stderr"
                exit 1
            }
        }
    '
}

# rr2_remaining — the resume set derived from the OUTCOME rows: every row whose
# status is not `succeeded`, in row (= topological) order. This is what the
# §H.2 `remaining:` continuation line must list (failed, parked, deferred,
# never-started, interrupted); fixtures compare the two rather than trusting
# either alone.
rr2_remaining() {
    rr2_outcome_rows | awk '$2 != "succeeded" { print $1 }'
}

# ─── Engine runner ──────────────────────────────────────────────────────────
# run_engine WORKSPACE [ARG...] — invoke the current engine with ARG... and
# capture combined stdout+stderr in FIXTURE_OUTPUT and the exit status in
# FIXTURE_RC. ALWAYS returns 0 (a failing engine is the fixture's data, not a
# reason to trip the fixture's own `set -e`) — assert on FIXTURE_RC explicitly,
# exactly like fixture-lib.bash's run_builder.
#
# Engine selection: GSA_TEST_ENGINE=fish|gsa (default fish).
#   fish — the staging engine: `fish "$WORKSPACE/build-all.fish" ARG...`,
#          byte-identical to how the existing fixtures invoke it today.
#   gsa  — the native engine: `gsa ARG...` with WORKSPACE as the working
#          directory (docs/gsa-contract.md is silent on how gsa locates a
#          workspace; see docs/gsa-fixture-migration.md "Contract gaps found").
#          The binary may be overridden with GSA_TEST_GSA_BIN (a fixture stub
#          path, or the real binary at cutover).
#
# ARG... is always the CURRENT engine's own argv — the per-fixture argv
# re-contract (docs/gsa-fixture-migration.md) flips the spelling at each phase;
# this function removes the engine identity from the call sites so that flip
# never touches the invocation mechanics. An unknown GSA_TEST_ENGINE is a loud
# usage error (FIXTURE_RC=2) naming the value and the two spellings.
run_engine() {
    local ws=${1:?run_engine: WORKSPACE argument required}
    shift
    local had_errexit=0
    [[ $- == *e* ]] && had_errexit=1
    set +e
    case ${GSA_TEST_ENGINE:-fish} in
    fish)
        FIXTURE_OUTPUT=$(fish "$ws/build-all.fish" "$@" 2>&1)
        FIXTURE_RC=$?
        ;;
    gsa)
        FIXTURE_OUTPUT=$(cd "$ws" && "${GSA_TEST_GSA_BIN:-gsa}" "$@" 2>&1)
        FIXTURE_RC=$?
        ;;
    *)
        FIXTURE_OUTPUT="run_engine: unknown engine '${GSA_TEST_ENGINE}' (want fish|gsa)"
        printf '%s\n' "$FIXTURE_OUTPUT" >&2
        FIXTURE_RC=2
        ;;
    esac
    ((had_errexit)) && set -e
    return 0
}

# ─── Stub-knob vocabulary (docs/gsa-contract.md §D.2) ───────────────────────
# GSA_FAKE_* names belong to FIXTURES, never to the engine: every knob a stub
# script reads is declared HERE and added here in the same change that
# introduces it. The engine's own inputs are exactly the §B.8 roster
# (GSA_STATE_DIR, GSA_LANES, GSA_JOBS, GSA_INTENSITY, GSA_CPU_THREADS,
# GSA_MEMORY_GIB, GSA_TARGET_CPU, GSA_VCS_SKIP_TOLERANCE); GSA_BUILD_JOBS is
# engine OUTPUT exported per lane. None of those is a stub knob and
# rr2_stub_knob rejects them by name.
#
# STAGING NOTE: fixtures that still source tests/lib/fixture-lib.bash read its
# (unchanged) fish-era table; this table is the v2 successor and carries the
# same knob names forward plus the knobs this migration introduces. The two
# tables coexist only until Phase 5 retires fixture-lib.bash's engine-era
# content — one fact, one home from cutover on (docs/gsa-fixture-migration.md).

declare -A GSA_FAKE_KNOB_TABLE=()

rr2_stub_knob() {
    local name=${1:?rr2_stub_knob: name required}
    local desc=${2:?rr2_stub_knob: description required}
    case $name in
    GSA_FAKE_*) ;;
    *)
        printf 'rr2_stub_knob: %s is not a GSA_FAKE_* name (engine inputs are the §B.8 roster, never stub knobs)\n' "$name" >&2
        return 1
        ;;
    esac
    if [[ -n ${GSA_FAKE_KNOB_TABLE[$name]+x} ]]; then
        [[ ${GSA_FAKE_KNOB_TABLE[$name]} == "$desc" ]] && return 0
        printf 'rr2_stub_knob: %s redeclared with a different description\n' "$name" >&2
        return 1
    fi
    GSA_FAKE_KNOB_TABLE[$name]=$desc
}

rr2_stub_knobs() {
    local k
    for k in "${!GSA_FAKE_KNOB_TABLE[@]}"; do
        printf '%s\t%s\n' "$k" "${GSA_FAKE_KNOB_TABLE[$k]}"
    done | sort
}

while IFS='|' read -r _knob _desc; do
    [[ -z $_knob ]] && continue
    rr2_stub_knob "$_knob" "$_desc"
done <<'EOF'
GSA_FAKE_BUILD_SECONDS|sleep duration of a stallable makepkg stub
GSA_FAKE_BUILD_SLEEP|log-ownership makepkg: hold the lane open for a mid-run signal
GSA_FAKE_CHOWN_LOG|log-ownership chown stub: invocation log
GSA_FAKE_DATE_COUNTER|sudo-keepalive fake date: virtual-clock counter
GSA_FAKE_DB_PATH|pacman-conf stub: DBPath answer, never the host db.lck
GSA_FAKE_DB_SEED|ignorepkg-register makepkg stub: drop a db.lck at build end
GSA_FAKE_DIR|stub scratch dir for curl/updpkgsums/makepkg call logs
GSA_FAKE_DURATIONS|scheduler-core-solo: per-package duration table
GSA_FAKE_ENGINE_LOG|engine stub (run_engine self-test): argv log
GSA_FAKE_ENGINE_RC|engine stub (run_engine self-test): exit status
GSA_FAKE_EXPECT_CONF|ignorepkg-register pacman stub: conf read at transaction time
GSA_FAKE_EXPECT_NAMES|that oracle: names the conf must cover at transaction time
GSA_FAKE_FAIL_PACKAGE|trivial makepkg stub: package id whose build must fail
GSA_FAKE_GCC_VERSION|toolchain-drift gcc stub: reported compiler identity
GSA_FAKE_INSTALLED_DIR|pacman stub: marker dir answering pacman -Q installed
GSA_FAKE_LANE_INTERVALS|scheduler-core-solo: START/END timestamp log
GSA_FAKE_LANE_MARKER|dashboard makepkg stub: lane-child PID log
GSA_FAKE_MAKEPKG_COUNT|install-archive-guard makepkg stub: invocation counter
GSA_FAKE_MAKEPKG_LOG|abi-batch makepkg stub: BUILD marker log
GSA_FAKE_MKTEMP_FAIL|anchor-defer mktemp stub: fail only the anchor scratch template
GSA_FAKE_MARKER_DIR|per-package build marker dir
GSA_FAKE_NO_ARCHIVE|install-archive-guard makepkg stub: build ok, archive absent
GSA_FAKE_PACMAN_ENV_LOG|PACMAN env-observation log
GSA_FAKE_PACMAN_LOG|trivial pacman stub: argv log
GSA_FAKE_PACMAN_RC|install-archive-guard pacman stub: exit status
GSA_FAKE_ARCHIVE_NAME|install-archive-guard makepkg stub: archive name
GSA_FAKE_CALL_PKGVER|install-archive-guard makepkg stub: run pkgver() like makepkg
GSA_FAKE_PRINTSRCINFO_FAIL|stable-sync-checksums makepkg stub: --printsrcinfo exits 1
GSA_FAKE_PGREP_HOLDER|pgrep stub: the pid reported as holding the lock
GSA_FAKE_QI|install-archive-guard pacman stub: pacman -Qi answer
GSA_FAKE_QI_ALL|abi-drift-install pacman stub: full installed-database dump
GSA_FAKE_QP|install-archive-guard pacman stub: pacman -Qp answer
GSA_FAKE_ROOT_FILE|log-ownership stat stub: the file reported root-owned
GSA_FAKE_ROOT_MODE|log-ownership id stub: answer root
GSA_FAKE_SIGNAL_LOG|signal-abort-lock makepkg stub: signal-receipt log
GSA_FAKE_SPAWN_LOG|spawned-helper argv/SPAWN-END log
GSA_FAKE_SED_LOG|stable-sync-checksums sed wrapper: argv log
GSA_FAKE_SI_MODE|stable-sync-checksums pacman stub: pacman -Si scenario
GSA_FAKE_SRCINFO_JOBS|srcinfo-freshness: parallelism of its printsrcinfo sweep
GSA_FAKE_STUB_PACMAN|path to the recorder the flock shim redirects pacman to
GSA_FAKE_STUB_PACMAN_LOG|that recorder's argv log
GSA_FAKE_SUDO_LOG|sudo stub: argv log
GSA_FAKE_SUDO_MODE|sudo stub: scenario mode
GSA_FAKE_SUDO_STATE|sudo stub: state dir
GSA_FAKE_TMP_WATCH|stable-sync-checksums makepkg stub: .SRCINFO temp names at exec
GSA_FAKE_TICKS|dashboard makepkg stub: tail-line count
EOF
unset _knob _desc
