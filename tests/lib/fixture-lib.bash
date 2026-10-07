#!/usr/bin/env bash
# tests/lib/fixture-lib.bash — fixture SYNTHESIS/INTERFACE helper. SOURCED, never
# executed as a fixture. Two conventions keep it out of the battery, and both are
# load-bearing (see tests/run-all.sh):
#   * the extension is .bash, not .sh — run-all.sh discovers fixtures with
#     `find . -name '*.sh'`, so this file can never be picked up as one;
#   * run-all.sh additionally excludes ./lib/* — defence in depth, so a future
#     tests/lib/anything.sh cannot become a phantom fixture either.
#
# Source it from a fixture (works both under `bash tests/<fixture>` via
# run-all.sh and under direct invocation, because the repo root is resolved
# from THIS file's BASH_SOURCE, not from run-all's exported root/work):
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
#
# SCOPE: synthesis and interface only. This file knows how to build the
# workspace skeleton every scheduler/install/cleanup fixture needs and how to
# write the trivial byte-identical stubs. Everything ORACLE-shaped stays
# inline in the fixture that gives it meaning: dashboard's TERM-immune ticking
# makepkg, sudo-keepalive's fake date and sudo modes, signal-abort-lock's
# signal loggers and flock/pgrep shims, scheduler-intensity's job-flag print
# and durations, scheduler-core-solo's interval recorder, abi-batch's
# marker-flipping pacman, install-archive-guard's -Qp/-Qi pacman oracle,
# pgo-payload-guard's staged archives. Assertions, fail() prefixes and the
# `( subshell )` section structure of multi-subject fixtures also stay inline.
#
# ─── Stub-variable vocabulary (fixture-side only; the builder must NOT change) ─
# Every knob a stub script reads is named GSA_FAKE_*. The builder's own seven
# inputs (GSA_LANES, GSA_JOBS, GSA_INTENSITY, GSA_CPU_THREADS, GSA_MEMORY_GIB,
# GSA_STATE_DIR, GSA_TARGET_CPU) and its output GSA_BUILD_JOBS keep their
# names and are NOT part of this vocabulary. Full final table:
#
#   GSA_FAKE_BUILD_SECONDS     sleep duration of a stallable makepkg stub
#                              (app-group, pacman-mutex-shim, scheduler-intensity,
#                              signal-abort-lock, sudo-keepalive)
#   GSA_FAKE_BUILD_SLEEP       log-ownership's makepkg: hold the lane open so a
#                              signal can land mid-run (was GSA_FIXTURE_BUILD_SLEEP)
#   GSA_FAKE_CHOWN_LOG         log-ownership chown stub: invocation log
#   GSA_FAKE_DATE_COUNTER      sudo-keepalive fake `date`: virtual-clock counter
#   GSA_FAKE_DB_PATH           pacman-conf stub's DBPath answer (pacman-mutex-shim,
#                              signal-abort-lock, ignorepkg-register) — never the
#                              host's real db.lck
#   GSA_FAKE_DB_SEED           ignorepkg-register makepkg stub: drop a db.lck at
#                              build end (the registration's bounded lock wait)
#   GSA_FAKE_DIR               stub scratch dir for curl/updpkgsums/makepkg call
#                              logs (anchor-defer, stable-sync-checksums)
#   GSA_FAKE_DURATIONS         scheduler-core-solo: per-package duration table
#   GSA_FAKE_EXPECT_CONF       ignorepkg-register pacman stub: conf the `pacman -U`
#                              oracle reads at transaction time
#   GSA_FAKE_EXPECT_NAMES      that oracle's names (space-separated) that the conf
#                              must already cover when the transaction runs
#   GSA_FAKE_FAIL_PACKAGE      trivial makepkg stub: package id whose build must
#                              fail (was GSA_FAIL_PACKAGE)
#   GSA_FAKE_GCC_VERSION       toolchain-drift's gcc stub: reported compiler
#                              identity used to detect build-tree drift
#   GSA_FAKE_INSTALLED_DIR     pacman stub: "$DIR/<pkg>" existing = `pacman -Q
#                              <pkg>` answers installed (toolchain-remediation)
#   GSA_FAKE_LANE_INTERVALS    scheduler-core-solo: START/END timestamp log
#   GSA_FAKE_LANE_MARKER       dashboard makepkg stub: lane-child PID log
#                              (was GSA_LANE_MARKER)
#   GSA_FAKE_MAKEPKG_COUNT     install-archive-guard makepkg stub: invocation
#                              counter (was GSA_FIXTURE_MAKEPKG_COUNT)
#   GSA_FAKE_MAKEPKG_LOG       abi-batch makepkg stub: BUILD marker log
#                              (was GSA_FIXTURE_MAKEPKG_LOG)
#   GSA_FAKE_MKTEMP_FAIL       anchor-defer mktemp stub: 'anchor' fails only
#                              the checksum anchor's scratch template
#   GSA_FAKE_MARKER_DIR        per-package build marker dir (abi-batch,
#                              log-ownership, pacman-mutex-shim, signal-abort-lock,
#                              sudo-keepalive)
#   GSA_FAKE_NO_ARCHIVE        install-archive-guard makepkg stub: "build
#                              succeeded, archive absent" (was GSA_FIXTURE_NO_ARCHIVE)
#   GSA_FAKE_PACMAN_ENV_LOG    PACMAN env-observation log (pacman-mutex-shim,
#                              signal-abort-lock)
#   GSA_FAKE_PACMAN_LOG        trivial pacman stub: argv log — `${VAR:?}`-guarded
#                              (was GSA_FIXTURE_PACMAN_LOG in install-archive-guard,
#                              resume-command, abi-batch-policy; the name also
#                              covers pgo-payload-guard's same-purpose stub)
#   GSA_FAKE_PACMAN_RC         install-archive-guard pacman stub: exit status
#                              (was GSA_FIXTURE_PACMAN_RC)
#   GSA_FAKE_ARCHIVE_NAME      install-archive-guard makepkg stub: archive name
#                              for shell-expanded pkgver coverage
#   GSA_FAKE_CALL_PKGVER       install-archive-guard makepkg stub: run pkgver()
#                              and model makepkg's updated PKGBUILD version
#   GSA_FAKE_PRINTSRCINFO_FAIL stable-sync-checksums makepkg stub: `--printsrcinfo`
#                              exits 1 (the .SRCINFO refresh-failure seam)
#   GSA_FAKE_PGREP_HOLDER      pgrep stub: THE pid "holding" the lock/db
#                              (local-db-repair, signal-abort-lock)
#   GSA_FAKE_QI                install-archive-guard pacman stub: `pacman -Qi`
#                              answer (was GSA_FIXTURE_QI)
#   GSA_FAKE_QI_ALL            abi-drift-install pacman stub: the full-dump
#                              (`pacman -Qi --`) installed database the
#                              stock-pinner query (abi_local_depend_rows)
#                              reads
#   GSA_FAKE_QP                install-archive-guard pacman stub: `pacman -Qp`
#                              answer (was GSA_FIXTURE_QP)
#   GSA_FAKE_ROOT_FILE         log-ownership stat stub: the file reported
#                              root-owned
#   GSA_FAKE_ROOT_MODE         log-ownership id stub: answer "root"
#   GSA_FAKE_SIGNAL_LOG        signal-abort-lock makepkg stub: signal-receipt log
#   GSA_FAKE_SPAWN_LOG         spawned-helper argv log (abi-batch-policy,
#                              texlive-split) (was GSA_SPAWN_LOG)
#   GSA_FAKE_SED_LOG           stable-sync-checksums sed wrapper: argv log
#                              proving which file the version rewrite edits
#   GSA_FAKE_SI_MODE           stable-sync-checksums pacman stub: `pacman -Si`
#                              scenario (db-error|not-found)
#   GSA_FAKE_SRCINFO_JOBS      srcinfo-freshness: parallelism of its own
#                              printsrcinfo sweep (was GSA_SRCINFO_JOBS)
#   GSA_FAKE_STUB_PACMAN       path to the recorder the flock shim redirects the
#                              baked /usr/bin/pacman to (pacman-mutex-shim,
#                              signal-abort-lock)
#   GSA_FAKE_STUB_PACMAN_LOG   that recorder's argv log
#   GSA_FAKE_SUDO_LOG          sudo stub: argv log
#   GSA_FAKE_SUDO_MODE         sudo stub: scenario mode (sudo-keepalive)
#   GSA_FAKE_SUDO_STATE        sudo stub: state dir (sudo-keepalive)
#   GSA_FAKE_TMP_WATCH         stable-sync-checksums makepkg stub: record the
#                              .SRCINFO temp names visible at exec
#   GSA_FAKE_TICKS             dashboard makepkg stub: tail-line count

# Repo root from this file's own location: tests/lib/fixture-lib.bash → repo.
_gsa_lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
gsa_repo_root=$(cd "$_gsa_lib_dir/../.." && pwd)

# The pkgver/pkgrel/arch triple most synthetic PKGBUILDs carry, for add_package's
# extra-pkglines. The trivial stubs' archive names assume exactly this shape
# ($id-1.0.0-1-any); a fixture whose stubs assume something else passes its own
# lines instead.
gsa_meta_any=$'pkgver=1.0.0\npkgrel=1\narch=(any)'

# make_install_conf PATH — the synthetic pacman.conf an INSTALL-path fixture
# passes to the builder as `_IGNOREPKG_CONF=<path>`. The dynamic IgnorePkg
# registration (2026-10-05) rewrites the target's [options] closure before
# pacman -U runs; without this seam the target is the HOST's /etc/pacman.conf,
# which no fixture may ever write. Point it at a per-FIXTURE (in practice
# per-run, since a fixture may stage several cases) file: the battery runs
# fixtures in parallel and registration is a read-modify-write with a dated
# pre-image backup, so one shared target would race and refuse on the backup.
# The file needs a real [options] section or the registration refuses — a
# fixture whose install must SUCCEED wants this skeleton, not a hand-rolled one.
make_install_conf() {
    cat >"$1" <<'EOF'
# synthetic pacman.conf — this fixture's dynamic IgnorePkg registration target
# (_IGNOREPKG_CONF), never the host's /etc/pacman.conf
[options]
HoldPkg = pacman glibc
EOF
}

# make_workspace DIR [lanes [jobs [intensity]]]
# Minimal but fully valid workspace skeleton: the loader validates every
# topology record and a full topological sort on EVERY invocation (--list,
# --audit, --help), so a fixture workspace must be complete or every run fails
# in the loader. Creates config/build-defaults.conf (lanes/jobs/intensity
# parameterised; the memory numbers are the fixtures' shared constants), an
# empty config/topology.conf (the header comment only — a valid empty
# topology) and an empty config/abi-exclusions.conf (header only — a valid
# empty ABI-guard exception registry; the loader tolerates its ABSENCE but a
# fixture that wants to EXERCISE the registry writes entries here), plus
# packages/ and bin/ for the fixture to fill.
# Fixture-specific records and anything after that belong to the fixture.
make_workspace() {
    local dir=$1 lanes=${2:-auto} jobs=${3:-auto} intensity=${4:-xhigh}
    mkdir -p "$dir/config" "$dir/packages" "$dir/bin"
    cp "$gsa_repo_root/build-all.fish" "$dir/build-all.fish"
    mkdir -p "$dir/lib" && cp "$gsa_repo_root/lib/sources.fish" "$gsa_repo_root/lib/audit.fish" "$dir/lib/"
    cat >"$dir/config/build-defaults.conf" <<EOF
lanes=$lanes
jobs=$jobs
intensity=$intensity
memory_per_job_gib=3
core_memory_per_job_gib=4
reserved_memory_gib=2
state_dir=auto
EOF
    cat >"$dir/config/topology.conf" <<'EOF'
# One record per package: id|path|groups|edges[|tags]
# (a lone id|path|groups| is a deliberate no-edge record)
EOF
    cat >"$dir/config/abi-exclusions.conf" <<'EOF'
# ABI-guard exception registry: id|reason|review-by (format doc in
# config/abi-exclusions.conf of the real repo; empty registry here)
EOF
}

# add_package DIR ID [extra-pkglines [group]]
# One synthetic package: a one-line PKGBUILD (`pkgname=ID`) — the shape most
# stub-driven fixtures need — plus its topology record (default group: git).
# extra-pkglines are appended to the PKGBUILD verbatim, so a fixture reproduces
# whatever metadata its own stubs key on (pkgver/pkgrel/arch for archive names,
# build() bodies, ...) without the helper guessing. A package in several groups
# or with edges/tags: rewrite the record with set_topology_record (appending
# group lists no longer exists — one record, one row).
add_package() {
    local dir=$1 id=$2 extra=${3:-} group=${4:-git}
    mkdir -p "$dir/packages/$id"
    {
        printf 'pkgname=%s\n' "$id"
        if [[ -n $extra ]]; then
            printf '%s\n' "$extra"
        fi
    } >"$dir/packages/$id/PKGBUILD"
    printf '%s|packages/%s|%s|\n' "$id" "$id" "$group" >>"$dir/config/topology.conf"
}

# set_topology_record DIR ID GROUPS [EDGES [TAGS]]
# Replace-or-append one package's topology record — the single writer for
# fixtures that grow a record beyond add_package's one-group no-edge shape
# (multi-group members, dependency edges, coupled-batch tags). GROUPS, EDGES
# and TAGS are comma lists; '' for EDGES is a deliberate no-edge record; omit
# TAGS (or pass '') for no tags. Record order is irrelevant to the loader, so
# a fresh record is simply appended.
set_topology_record() {
    local dir=$1 id=$2 groups=$3 edges=${4:-} tags=${5:-}
    local file=$dir/config/topology.conf tmp=$dir/config/topology.conf.tmp
    local record="$id|packages/$id|$groups|$edges"
    if [[ -n $tags ]]; then
        record="$record|$tags"
    fi
    awk -v id="$id" 'index($0, id "|") != 1' "$file" >"$tmp"
    printf '%s\n' "$record" >>"$tmp"
    mv "$tmp" "$file"
}

# stub_sudo DIR — the sudo passthrough stub: strips the builder's
# non-interactive flags (-n/-v/--) and execs the rest, so
# `sudo -n pacman -U ...` reaches the fixture's pacman stub. --preserve-env is
# stripped too: some hosts wrap `sudo` in a fish function that re-execs it as
# `command sudo --preserve-env ...`, and real sudo accepts that flag — a stub
# that chokes on it makes every -i fixture fail in the preflight probe.
stub_sudo() {
    cat >"$1/bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -u
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

# stub_pacman DIR — the pacman log stub: appends every argv to
# $GSA_FAKE_PACMAN_LOG and exits 0. Oracle-shaped pacman stubs (-Qp/-Qi
# answers, -Si repo data, marker flipping) stay inline in their fixtures.
stub_pacman() {
    cat >"$1/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'pacman %s\n' "$*" >>"${GSA_FAKE_PACMAN_LOG:?}"
exit 0
EOF
    chmod +x "$1/bin/pacman"
}

# stub_makepkg DIR — the trivial makepkg stub: fails the package named by
# $GSA_FAKE_FAIL_PACKAGE, otherwise touches a 1.0.0-1-any archive and echoes
# its startdir. The archive name assumes add_package extras of
# pkgver=1.0.0 / pkgrel=1 / arch=(any); a stub that stamps, times, sleeps or
# signals is an oracle and stays inline in its fixture.
stub_makepkg() {
    cat >"$1/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
id=$(basename "$PWD")
[[ "${GSA_FAKE_FAIL_PACKAGE:-}" == "$id" ]] && exit 1
: >"$PWD/$id-1.0.0-1-any.pkg.tar.zst"
printf 'fake makepkg %s\n' "$PWD"
exit 0
EOF
    chmod +x "$1/bin/makepkg"
}

# stub_sleep DIR — the capped-sleep stub. The builder's own long waits are
# pure latency no fixture asserts on — the VCS transport-retry backoffs in
# lib/sources.fish (2 s/5 s/10 s), the dispatcher's 0.5 s poll cycle, the
# bounded db.lck poll — and at fixture scale they dwarf the work under test
# (skip-upstream burned ~45 s of its ~135 s in retry backoffs alone; a stub
# package dispatch costs one 0.5 s poll cycle). A `sleep` stub on PATH
# re-runs /usr/bin/sleep with every numeric operand >= 0.4 s replaced by
# 0.05 s; SHORTER operands pass through unchanged, so fixture-side polling
# (0.05-0.3 s loops and their iteration budgets) keeps its exact cadence.
# Only install it where no long sleep is a lease or a measured duration: the
# `sleep 60 60<"$lock"` lock-holder of signal-abort-lock/local-db-repair,
# run-record's `sleep 3` mid-build stall and scheduler-core-solo's duration
# table all need real time and must never see this stub.
stub_sleep() {
    cat >"$1/bin/sleep" <<'EOF'
#!/usr/bin/env bash
set -u
args=()
for a in "$@"; do
    ip=${a%%.*}
    fp=0
    [[ $a == *.* ]] && fp=${a#*.}
    fp=${fp:0:1}
    if [[ $ip =~ ^[0-9]+$ && $fp =~ ^[0-9]$ ]] && ((ip >= 1 || (ip == 0 && fp >= 4))); then
        a=0.05
    fi
    args+=("$a")
done
exec /usr/bin/sleep "${args[@]}"
EOF
    chmod +x "$1/bin/sleep"
}

# run_builder CMD [ARG...] — the capture helper. Runs the command with combined
# stdout+stderr captured in FIXTURE_OUTPUT and its exit status in FIXTURE_RC.
# ALWAYS returns 0 (a failing builder is the fixture's data, not a reason to
# trip the fixture's own `set -e`) — assert on FIXTURE_RC explicitly. A fixture
# that wants `if run_builder ...` status semantics wraps this in a local
# one-liner that returns $FIXTURE_RC.
run_builder() {
    local had_errexit=0
    [[ $- == *e* ]] && had_errexit=1
    set +e
    FIXTURE_OUTPUT=$("$@" 2>&1)
    FIXTURE_RC=$?
    ((had_errexit)) && set -e
    return 0
}

# makepkg_printsrcinfo DIR — `makepkg --printsrcinfo` with GIT_CONFIG_COUNT=0:
# agent shells inject git config (safe.bareRepository=explicit) that breaks
# makepkg VCS operations, so every printsrcinfo call carries that override.
# stdout/stderr pass through; the caller redirects and checks the status.
makepkg_printsrcinfo() {
    GIT_CONFIG_COUNT=0 makepkg --printsrcinfo --dir "$1"
}

# ─── Run-record parsing — the machine-block interface ────────────────────────
# print_run_record emits one bounded block at the end of every started run:
#
#   --- run record begin ---
#   format: 1
#   selection-source: groups=… packages=… ranges=…
#   order: p1 p2 p3
#   lanes: N
#   normal-jobs: N
#   core-jobs: N
#   intensity: LEVEL
#   outcome: success|failed|interrupted
#   rc: N
#   pkg status rc dur reason      ← one row per package, topological order
#   --- run record end ---
#
# These helpers parse that block out of a captured builder run (the combined
# stdout+stderr run_builder produces, or a fixture's own capture file). All
# of them read stdin, so both `<<<"$output"` and `<"$dir/out.txt"` work;
# trailing CR is stripped first, so PTY captures parse like pipe output. Each
# helper fails loudly when the block is missing or duplicated instead of
# letting a fixture fall back to asserting on prose outside it. Everything
# derived stays in the fixture: these four parse, they do not interpret.

# rr_extract — the block BODY (between the two markers, exclusive). Fails
# unless exactly one block is present.
rr_extract() {
    awk '
        { sub(/\r$/, "") }
        /^--- run record begin ---$/ { blocks++; inb = 1; next }
        /^--- run record end ---$/ { inb = 0; next }
        inb { print }
        END {
            if (blocks != 1) {
                printf("rr_extract: expected exactly one run-record block, saw %d\n", blocks) > "/dev/stderr"
                exit 1
            }
        }
    '
}

# rr_scalar KEY — the value of one `key: value` plan scalar (format,
# selection-source, order, lanes, normal-jobs, core-jobs, intensity, outcome,
# rc). Fails when the key is absent.
rr_scalar() {
    rr_extract | awk -v key="$1" '
        index($0, key ": ") == 1 && !found {
            print substr($0, length(key) + 3)
            found = 1
        }
        END {
            if (!found) {
                printf("rr_scalar: no %s scalar in the run record\n", key) > "/dev/stderr"
                exit 1
            }
        }
    '
}

# rr_rows — the package rows only (`pkg status rc dur reason`, one per line,
# topological order). Anything non-empty that is not a `key: value` scalar is
# a row, so a malformed row stays visible to the fixture's grammar check
# instead of being filtered away here.
rr_rows() {
    rr_extract | awk 'NF > 0 && $0 !~ /^[a-z0-9-]+: / { print }'
}

# rr_row PKG [status|rc|dur|reason] — one package's row, or one of its
# fields (field names mirror the builder's own run_record_field). The reason
# is the remainder of the line. Fails when the package has no row.
rr_row() {
    rr_rows | awk -v pkg="$1" -v field="${2:-}" '
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
                printf("rr_row: package %s has no run-record row\n", pkg) > "/dev/stderr"
                exit 1
            }
            if (bad) {
                printf("rr_row: unknown field %s (want status|rc|dur|reason)\n", field) > "/dev/stderr"
                exit 1
            }
        }
    '
}

# rr_remaining — the resume set: every row whose status is not `succeeded`,
# in row (= topological) order. This is exactly what the builder's
# continuation suggestion lists — a failed package must rebuild BEFORE its
# dependents, so it stays in (2026-09-26).
rr_remaining() {
    rr_rows | awk '$2 != "succeeded" { print $1 }'
}
