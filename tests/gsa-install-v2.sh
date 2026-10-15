#!/usr/bin/env bash
set -euo pipefail

# tests/gsa-install-v2.sh — Phase-3 install semantics of the NATIVE engine
# (`gsa`, docs/gsa-contract.md §D/§E/§G/§I/§K). Everything here is synthetic:
# $TMPDIR workspaces, fabricated pacman local databases, and stub
# `makepkg`/`sudo`/`pacman`/`pacman-conf` executables — no transaction ever
# reaches the host, no conf outside the fixture tree is read or written.
# Expectations are DERIVED from the staged archives, the fabricated DB entries
# and the run records the runs produced (rule 25(j) / contract §L.3) — never
# from pinned counts: expected versions are the versions this fixture staged,
# expected names come from the staged `.PKGINFO`s, expected order/parks come
# from the fixture's own build-order edges.
#
# Pinned here (seven ( subshell ) sections, one per scenario; run one alone
# with GSA_INSTALL_V2_ONLY=a…g):
#   a. decision rows (§E.2/§E.3) through `--install-decide checked|force`
#      (§D.1: rc 0 plan / 1 refusal / 2 bad usage, touches nothing): install,
#      skip (`already-current` — the same-version + install-date rule, plus
#      its doubt-installs half), refuse (`pgo-*`, `abi-soname`, `needed` —
#      gates force mode never bypasses); `noop empty-list` where §E.3 defines
#      it (`-Ua`, zero eligible archives); `parked` where it is observable —
#      the cone-stop park row of an `-S` install refusal. NOTE (gap,
#      reported): a decision-row `parked` needs `DecisionContext.parks`, which
#      no production caller populates, so the seam never emits one; the park
#      is observable only as the run-record row (§E.3 "the row records the
#      park").
#   b. `gsa -S` installs each package BEFORE its consumers compile (rule 11):
#      per-edge ordering proven from the stub clocks (a provider's `pacman -U`
#      ends before its consumer's makepkg spawn), plan rows `build-install`,
#      record order topological over the fixture's own edges.
#   c. exactly ONE `pacman -U` at a time (§K.3): transaction windows from the
#      stub log never overlap, every argv is the §K.3 shape, and the
#      `-- <pacman args…>` passthrough (§B.1) lands before the archives.
#   d. force mode bypasses the same-version skip (§B.6 `-Uf` / `f`): checked
#      skips (zero transactions), force installs (exactly one), and the same
#      pair at the `--install-decide` seam.
#   e. install refusal = rc 3 and ZERO pacman calls (rule 25(h), fail-closed):
#      a `-U` refusal reaches neither pacman nor sudo nor the registration
#      (conf byte-identical), and an `-S` install refusal stops the run with
#      the consumer cone never compiling — a build that succeeded still
#      transacts nothing.
#   f. `db.lck` is never deleted (rule 23/§K.3): a stale lock is announced,
#      never touched, and the registration still lands beside it.
#   g. an interrupt mid-install (§I.3/§K.3) leaves no half-registered
#      IgnorePkg closure: the registration is atomic (every accepted name or
#      none, no temp residue, dated pre-image kept) while the run exits 130
#      with the full record.
#
# House conventions: `( subshell )` sections (each an isolated scenario with
# its own workspace), inline oracle stubs (§D.2), `fail()` prefixes, and
# tests/lib/rr-v2.bash's `format: 2` parser + run_engine with
# GSA_TEST_ENGINE=gsa. `-U` run records are strict-`format: 2`-parseable
# since the cutover gap-(a) fix: integer budget scalars (a transaction run
# dispatches no lanes — `lanes: 0`) and one plan/outcome row per SUBJECT
# (multi-row candidates — several PGO hits, a split set — collapse in the
# record; the seam's per-candidate §E.2 rows are the first rendering and
# keep full granularity), so every record below parses through rr2_*. The
# helpers `record_scalar`/`record_section` are thin rr2_* wrappers.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"

fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-install-v2.XXXXXX")
# root-safe cleanup: engine state under $fixture is root-owned (W5 §B.10)
trap '/usr/bin/sudo -n rm -rf -- "$fixture" 2>/dev/null || rm -rf -- "$fixture" 2>/dev/null || true' EXIT

fail() {
    printf '%s\n' "$1" >&2
    if [ -n "${2:-}" ] && [ -f "$2" ]; then
        sed 's/^/    /' "$2" >&2
    fi
    exit 1
}

# Section filter: GSA_INSTALL_V2_ONLY=<a..g> runs exactly one section.
want() { [ -z "${GSA_INSTALL_V2_ONLY:-}" ] || [ "${GSA_INSTALL_V2_ONLY}" = "$1" ]; }

# ─── Stub-knob vocabulary (§D.2: declared here in the change that adds them) ─
rr2_stub_knob GSA_FAKE_PACMAN_SLEEP "gsa-install-v2 pacman stub: stall inside one transaction (interrupt and overlap probes)"
rr2_stub_knob GSA_FAKE_ELF_PACKAGE "gsa-install-v2 makepkg stub: package id whose archive ships the DT_NEEDED probe ELF"
rr2_stub_knob GSA_FAKE_ELF_SRC "gsa-install-v2 makepkg stub: path of the probe ELF copied into the archive"
rr2_stub_knob GSA_FAKE_PGO_PACKAGE "gsa-install-v2 makepkg stub: package id whose archive ships a baked .gcda destination"
rr2_stub_knob GSA_FAKE_ENGINE_PID "gsa-install-v2 engine wrapper: pidfile of the engine process to signal"

# ─── The engine under test: built into the fixture tree (scratch only).
# GSA_TEST_GSA_BIN, when already set to an executable, is that engine (the
# rr-v2.bash run_engine convention) and the scratch build is skipped — used
# only by development/sweep runs against a prebuilt binary; the battery path
# builds the tree it tests. ─────────────────────────────────────────────────
if [ -z "${GSA_TEST_GSA_BIN:-}" ]; then
    cargo build --offline --quiet --target-dir "$fixture/cargo" -p gsa-cli \
        --manifest-path "$gsa_repo_root/Cargo.toml" \
        || fail "cannot build the gsa binary for the fixture"
    GSA_TEST_GSA_BIN="$fixture/cargo/debug/gsa"
fi
[ -x "$GSA_TEST_GSA_BIN" ] || fail "the engine under test is not executable: $GSA_TEST_GSA_BIN"
export GSA_TEST_ENGINE=gsa
export GSA_TEST_GSA_BIN

# ─── Oracle stubs and derivation helpers (inline: §D.2 keeps oracles in the
# fixture that gives them meaning) ──────────────────────────────────────────

# write_elf64_needed FILE SONAME — a minimal section-less ELF64 (ET_DYN)
# carrying exactly one DT_NEEDED, byte layout after the oracle in
# crates/gsa-recipe/src/elf.rs (ehdr | PT_LOAD | PT_DYNAMIC | dyn entries |
# dynstr). This is the file truth the NEEDED probe (rule 25(e)) reads.
write_elf64_needed() {
    local out=$1 soname=$2
    local dynstr_len=$((${#soname} + 2)) dynstr_off=240 total
    total=$((dynstr_off + dynstr_len))
    u16() { printf "$(printf '\\x%02x\\x%02x' $(($1 & 255)) $((($1 >> 8) & 255)))"; }
    u32() { printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $(($1 & 255)) $((($1 >> 8) & 255)) $((($1 >> 16) & 255)) $((($1 >> 24) & 255)))"; }
    u64() {
        local v=$1 s='' i
        for i in $(seq 0 7); do s="$s$(printf '\\x%02x' $(((v >> (8 * i)) & 255)))"; done
        printf "$s"
    }
    {
        printf '\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00'
        u16 3; u16 62; u32 1; u64 0; u64 64; u64 0; u32 0
        u16 64; u16 56; u16 2; u16 64; u16 0; u16 0
        u32 1; u32 5; u64 0; u64 0; u64 0; u64 "$total"; u64 "$total"; u64 4096
        u32 2; u32 6; u64 176; u64 176; u64 176; u64 64; u64 64; u64 8
        u64 1; u64 1
        u64 5; u64 "$dynstr_off"
        u64 10; u64 "$dynstr_len"
        u64 0; u64 0
        printf '\x00%s\x00' "$soname"
    } >"$out"
}

# stage_pkginfo STAGE PKGBASE PKGNAME PKGVER EPOCH [PKGLINE…] — the staged
# `.PKGINFO` of one hand-built archive. The canonical version the engine
# derives is EPOCH:PKGVER; every expectation here computes the same string.
stage_pkginfo() {
    local stage=$1 base=$2 name=$3 ver=$4 epoch=$5
    shift 5
    mkdir -p "$stage"
    {
        printf 'pkgbase = %s\n' "$base"
        printf 'pkgname = %s\n' "$name"
        printf 'pkgver = %s\n' "$ver"
        printf 'epoch = %s\n' "$epoch"
        printf 'arch = any\n'
        if [ "$#" -gt 0 ]; then
            printf '%s\n' "$@"
        fi
    } >"$stage/.PKGINFO"
}

# make_archive OUT STAGE — one `.pkg.tar.zst` from a prepared stage dir (a
# single tar pass: a compressed archive can never be appended to). The stage
# is consumed.
make_archive() {
    local out=$1 stage=$2
    mkdir -p "$(dirname "$out")"
    if [ -d "$stage/usr" ]; then
        tar --zstd -cf "$out" -C "$stage" .PKGINFO usr
    else
        tar --zstd -cf "$out" -C "$stage" .PKGINFO
    fi
    rm -rf -- "$stage"
}

# db_install DBROOT NAME FULL-VERSION [PROVIDE…] — one fabricated pacman
# local-DB entry (`<db>/local/<name>-<ver>/{desc,files}`), like the fish-era
# fixtures' DBs (docs/NOTE.md:89-93: fixtures never read host state). The
# entry directory's mtime IS the install date (crates/gsa-install localdb.rs),
# so the caller touches it to place the date against the archive.
db_install() {
    local db=$1 name=$2 version=$3
    shift 3
    local dir="$db/local/$name-$version"
    mkdir -p "$dir"
    {
        printf '%%NAME%%\n%s\n\n' "$name"
        printf '%%VERSION%%\n%s\n\n' "$version"
        printf '%%BASE%%\n%s\n' "$name"
        if [ "$#" -gt 0 ]; then
            printf '\n%%PROVIDES%%\n'
            printf '%s\n' "$@"
        fi
    } >"$dir/desc"
    printf '%%FILES%%\n' >"$dir/files"
    printf '%s\n' "$dir"
}

# write_stub_makepkg DIR — the scenario makepkg: SPAWN/END lines (nanosecond
# timestamps) for dispatch/install-ordering observation, one real
# `.pkg.tar.zst` per build (staged `.PKGINFO`), plus the two payload knobs:
# the DT_NEEDED probe ELF (GSA_FAKE_ELF_PACKAGE/…_SRC) and a baked profiling
# destination (GSA_FAKE_PGO_PACKAGE) — the two refuse-gate witnesses that must
# reach the install decision from a REAL build.
write_stub_makepkg() {
    cat >"$1/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
id=$(basename "$PWD")
printf 'SPAWN %s %s\n' "$id" "$(date +%s%N)" >>"${GSA_FAKE_SPAWN_LOG:?}"
stage="$PWD/.stage-$id"
mkdir -p "$stage"
{
    printf 'pkgbase = %s\n' "$id"
    printf 'pkgname = %s\n' "$id"
    printf 'pkgver = 1.0.0-1\n'
    printf 'arch = any\n'
} >"$stage/.PKGINFO"
if [ "$id" = "${GSA_FAKE_ELF_PACKAGE:-}" ]; then
    mkdir -p "$stage/usr/lib"
    cp "${GSA_FAKE_ELF_SRC:?}" "$stage/usr/lib/libx.so"
fi
if [ "$id" = "${GSA_FAKE_PGO_PACKAGE:-}" ]; then
    mkdir -p "$stage/usr/lib"
    printf '# baked /home/u/build/train.gcda\n' >"$stage/usr/lib/libp.so"
fi
if [ -d "$stage/usr/lib" ]; then
    tar --zstd -cf "$PWD/$id-1.0.0-1-any.pkg.tar.zst" -C "$stage" .PKGINFO usr
else
    tar --zstd -cf "$PWD/$id-1.0.0-1-any.pkg.tar.zst" -C "$stage" .PKGINFO
fi
rm -rf "$stage"
printf 'END %s %s\n' "$id" "$(date +%s%N)" >>"${GSA_FAKE_SPAWN_LOG:?}"
exit 0
EOF
    chmod +x "$1/bin/makepkg"
}

# write_stub_sudo DIR — the sudo passthrough stub with an argv log: the
# engine may only ever run `sudo -n <cmd>` (§K.3); the log is the fixture's
# evidence of what (never) escalated.
write_stub_sudo() {
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

# write_stub_pacman DIR — the transaction oracle: one TXN-START / argv /
# TXN-END triple per invocation (nanosecond timestamps: overlap and
# install-ordering asserts read these), and a stall inside the transaction
# window (GSA_FAKE_PACMAN_SLEEP) so an interrupt can land mid-`pacman -U`.
write_stub_pacman() {
    cat >"$1/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'TXN-START %s\n' "$(date +%s%N)" >>"${GSA_FAKE_PACMAN_LOG:?}"
printf 'pacman %s\n' "$*" >>"${GSA_FAKE_PACMAN_LOG:?}"
sleep "${GSA_FAKE_PACMAN_SLEEP:-0}"
printf 'TXN-END %s\n' "$(date +%s%N)" >>"${GSA_FAKE_PACMAN_LOG:?}"
exit 0
EOF
    chmod +x "$1/bin/pacman"
}

# write_stub_pacman_conf DIR DBROOT — `pacman-conf DBPath` answers the
# fixture's fabricated DB root, never the host's (§D.1 stays pacman-free).
write_stub_pacman_conf() {
    cat >"$1/bin/pacman-conf" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = DBPath ] && printf '%s\n' "$2"
exit 0
EOF
    chmod +x "$1/bin/pacman-conf"
}

# install_ws DIR DBROOT — one workspace with all four stubs on PATH and the
# fixture's fabricated DB wired in. Every run in this fixture goes through it.
install_ws() {
    local ws=$1 db=$2
    write_stub_makepkg "$ws"
    write_stub_sudo "$ws"
    write_stub_pacman "$ws"
    write_stub_pacman_conf "$ws" "$db"
    export PATH="$ws/bin:$PATH"
}

# rows_only — the §E.2 decision rows of a capture, as printed by the seam or
# by a `--dry-run` plan (rows come before the prose/record span; the record's
# plan rows share the framing and are excluded with it).
rows_only() {
    awk '
        /^--- run record begin ---/ || /^Build run: / { exit }
        /^[A-Za-z0-9@._+-]+ (install|skip|refuse|noop|parked) / { print }
    '
}

# assert_row BLOB SUBJECT DECISION REASON-REGEX WHAT — one decision row
# (§E.2 grammar: `subject decision reason…`, the reason is the remainder).
assert_row() {
    local blob=$1 subject=$2 decision=$3 reason_re=$4 what=$5
    grep < <(printf '%s\n' "$blob" | awk -v s="$subject" -v d="$decision" '
        $1 == s && $2 == d { print; found = 1 }
        END { exit !found }') -Eq "^[^ ]+ $decision $reason_re$" \
        || fail "$what: want row '$subject $decision $reason_re …' (§E.2), got rows:
$blob"
}

# assert_no_row BLOB SUBJECT DECISION WHAT — the row must be absent.
assert_no_row() {
    local blob=$1 subject=$2 decision=$3 what=$4
    if printf '%s\n' "$blob" | awk -v s="$subject" -v d="$decision" '
        $1 == s && $2 == d { found = 1 }
        END { exit !found }'; then
        fail "$what: row '$subject $decision' must be absent (§E.3), got rows:
$blob"
    fi
}

# record_scalar KEY — one scalar of the machine block of a capture, through
# the STRICT `format: 2` parser (rr2_body fails loudly on any grammar break,
# which is exactly the §H.2 conformance check this fixture keeps).
record_scalar() {
    rr2_scalar "$1" <<<"$FIXTURE_OUTPUT"
}

# record_section plan|outcome — one section's rows of the machine block.
record_section() {
    case $1 in
    plan) rr2_plan_rows <<<"$FIXTURE_OUTPUT" ;;
    outcome) rr2_outcome_rows <<<"$FIXTURE_OUTPUT" ;;
    *) fail "record_section: unknown section $1" ;;
    esac
}

# txn_count / txn_argv / txn_intervals — the pacman stub log's facts.
# txn_count counts TRANSACTIONS (`pacman -U`), not invocations: the toolchain
# preflight's read-only `pacman -Q rust-git` probe runs on every build-family
# run (2026-10-14, the probe-gating decision) and is never a transaction.
txn_count() { grep -c '^pacman -U ' "$1" || true; }
txn_argv() { sed -n 's/^pacman //p' "$1"; }
txn_intervals() { awk '/^TXN-START /{print "s", $2} /^TXN-END /{print "e", $2}' "$1"; }

# assert_txn_serial LOG WHAT — no two transaction windows overlap (§K.3),
# and there is at least one window (never a vacuous pass).
assert_txn_serial() {
    local log=$1 what=$2
    txn_intervals "$log" | sort -k2,2n | awk -v what="$what" '
        $1 == "s" && open { printf("%s: transaction windows overlap at %s\n", what, $2) > "/dev/stderr"; bad = 1 }
        $1 == "s" { open = 1; n++ }
        $1 == "e" { open = 0 }
        END {
            if (n == 0) { printf("%s: no transaction recorded\n", what) > "/dev/stderr"; bad = 1 }
            exit bad
        }' || fail "$what: transactions are not serialized (one pacman -U at a time, §K.3):" "$log"
}

# spawn_ts ID LOG — the stub clock of one makepkg spawn; txn_end_for
# ARCHIVE-NAME LOG — the stub clock of the transaction installing it.
spawn_ts() { awk -v id="$1" '$1 == "SPAWN" && $2 == id { print $3; exit }' "$2"; }
txn_end_for() {
    awk -v name="$1" '
        /^pacman / { hit = index($0, name) > 0 }
        /^TXN-END / && hit { print $2; hit = 0 }
    ' "$2"
}

if want a; then
    # ─── 1. decision rows: install / skip / refuse / noop / parked (§E) ─────
    (
        set -euo pipefail
        ws="$fixture/a/ws"
        db="$fixture/a/db"
        make_workspace "$ws" 1 auto low
        install_ws "$ws" "$db"
        mkdir -p "$db"
        export GSA_FAKE_SPAWN_LOG="$fixture/a/spawn.log"
        export GSA_FAKE_PACMAN_LOG="$fixture/a/pacman.log"
        export GSA_FAKE_SUDO_LOG="$fixture/a/sudo.log"

        ver="1.2.3-4"
        epoch=7
        canon="$epoch:$ver"

        # staged candidates (every archive carries its own .PKGINFO truth)
        for name in one samever doubt abipkg neededpkg pgopkg; do
            mkdir -p "$ws/packages/$name"
        done
        stage="$fixture/a/stage"
        stage_pkginfo "$stage" one one "$ver" "$epoch"
        make_archive "$ws/packages/one/one-$ver-any.pkg.tar.zst" "$stage"
        stage_pkginfo "$stage" samever samever "$ver" "$epoch"
        make_archive "$ws/packages/samever/samever-$ver-any.pkg.tar.zst" "$stage"
        stage_pkginfo "$stage" doubt doubt "$ver" "$epoch"
        make_archive "$ws/packages/doubt/doubt-$ver-any.pkg.tar.zst" "$stage"
        stage_pkginfo "$stage" abipkg abipkg "$ver" "$epoch" 'provides = libfoo.so=2-64'
        make_archive "$ws/packages/abipkg/abipkg-$ver-any.pkg.tar.zst" "$stage"
        write_elf64_needed "$fixture/a/probe.elf" libmissing.so.9
        stage_pkginfo "$stage" neededpkg neededpkg "$ver" "$epoch"
        mkdir -p "$stage/usr/lib"
        cp "$fixture/a/probe.elf" "$stage/usr/lib/libx.so"
        make_archive "$ws/packages/neededpkg/neededpkg-$ver-any.pkg.tar.zst" "$stage"
        stage_pkginfo "$stage" pgopkg pgopkg "$ver" "$epoch"
        mkdir -p "$stage/usr/lib"
        printf '# baked /home/u/build/train.gcda\n' >"$stage/usr/lib/libp.so"
        make_archive "$ws/packages/pgopkg/pgopkg-$ver-any.pkg.tar.zst" "$stage"
        # PGO witness: only an instrumented recipe can leak a payload (§E.3)
        printf 'pkgname=pgopkg\npkgver=1.2.3\npkgrel=4\narch=(any)\nCFLAGS+=" -fprofile-generate=/tmp/p"\n' \
            >"$ws/packages/pgopkg/PKGBUILD"

        # fabricated installed DB (install dates are entry-dir mtimes)
        samever_dir=$(db_install "$db" samever "$canon")
        doubt_dir=$(db_install "$db" doubt "$canon")
        abipkg_dir=$(db_install "$db" abipkg "$canon" 'libfoo.so=1-64')
        touch "$samever_dir" "$abipkg_dir"               # installed "now": not older than the archives
        touch -d '2001-01-01 00:00:00' "$doubt_dir"       # older than the archive: doubt installs

        one="$ws/packages/one/one-$ver-any.pkg.tar.zst"
        same="$ws/packages/samever/samever-$ver-any.pkg.tar.zst"
        doubt="$ws/packages/doubt/doubt-$ver-any.pkg.tar.zst"
        abi="$ws/packages/abipkg/abipkg-$ver-any.pkg.tar.zst"
        needed="$ws/packages/neededpkg/neededpkg-$ver-any.pkg.tar.zst"
        pgo="$ws/packages/pgopkg/pgopkg-$ver-any.pkg.tar.zst"

        # ── install: nothing installed for the name → install ok (both modes)
        run_engine "$ws" --install-decide checked "$one"
        [ "$FIXTURE_RC" = 0 ] || fail "a clean checked plan is rc 0 (§E.5), got $FIXTURE_RC: $FIXTURE_OUTPUT"
        assert_row "$(printf '%s\n' "$FIXTURE_OUTPUT" | rows_only)" one install 'ok' "checked fresh install (§E.3)"
        run_engine "$ws" --install-decide force "$one"
        [ "$FIXTURE_RC" = 0 ] || fail "a clean force plan is rc 0 (§E.5), got $FIXTURE_RC: $FIXTURE_OUTPUT"
        assert_row "$(printf '%s\n' "$FIXTURE_OUTPUT" | rows_only)" one install 'ok' "force fresh install (§E.3)"

        # ── skip: same canonical version + install date not older than the
        # archive → `skip already-current <version>` (the version is the one
        # this fixture staged and installed — derived, never pinned)
        run_engine "$ws" --install-decide checked "$same"
        [ "$FIXTURE_RC" = 0 ] || fail "a skip-only plan is rc 0 (§E.5), got $FIXTURE_RC: $FIXTURE_OUTPUT"
        rows=$(printf '%s\n' "$FIXTURE_OUTPUT" | rows_only)
        assert_row "$rows" samever skip "already-current $canon" "checked same-version skip (rule 11)"
        assert_no_row "$rows" samever install "checked same-version skip (rule 11)"

        # ── the skip rule's other half: the same version but an OLDER
        # install date is doubt, and doubt installs (rule 11)
        run_engine "$ws" --install-decide checked "$doubt"
        rows=$(printf '%s\n' "$FIXTURE_OUTPUT" | rows_only)
        assert_row "$rows" doubt install 'ok' "doubt installs (install date older than the archive)"

        # ── refuse PGO payload (§E.3 pgo-*): one candidate, full rows
        run_engine "$ws" --install-decide checked "$pgo"
        [ "$FIXTURE_RC" = 1 ] || fail "a refusing plan is rc 1 (§E.5), got $FIXTURE_RC: $FIXTURE_OUTPUT"
        rows=$(printf '%s\n' "$FIXTURE_OUTPUT" | rows_only)
        assert_row "$rows" pgopkg refuse "pgo-hit $pgo usr/lib/libp.so" "PGO payload refusal (rule 25(h))"
        assert_row "$rows" pgopkg refuse "pgo-instrumented $pgo" "PGO payload refusal (rule 25(h))"

        # ── refuse ABI provide drift (§E.3 abi-soname): the installed
        # auto-version 1-64 moves to 2-64 in the build
        run_engine "$ws" --install-decide checked "$abi"
        [ "$FIXTURE_RC" = 1 ] || fail "an ABI refusal is rc 1 (§E.5), got $FIXTURE_RC: $FIXTURE_OUTPUT"
        rows=$(printf '%s\n' "$FIXTURE_OUTPUT" | rows_only)
        assert_row "$rows" abipkg refuse "abi-soname $abi abipkg libfoo.so 1-64 2-64" "ABI provide-drift refusal (rule 25(a))"

        # ── refuse NEEDED miss (§E.3 needed): the archive's own ELF member
        # needs a soname nothing resolves (rule 25(b)/(e))
        run_engine "$ws" --install-decide checked "$needed"
        [ "$FIXTURE_RC" = 1 ] || fail "a NEEDED refusal is rc 1 (§E.5), got $FIXTURE_RC: $FIXTURE_OUTPUT"
        rows=$(printf '%s\n' "$FIXTURE_OUTPUT" | rows_only)
        assert_row "$rows" neededpkg refuse "needed $needed usr/lib/libx.so libmissing.so.9" "NEEDED-probe refusal (rule 25(e))"

        # ── force bypasses the same-version skip, NEVER the safety gates
        run_engine "$ws" --install-decide force "$same"
        rows=$(printf '%s\n' "$FIXTURE_OUTPUT" | rows_only)
        assert_row "$rows" samever install 'ok' "force bypasses the same-version skip (§B.6)"
        for pair in "$pgo|PGO payload|pgopkg" "$abi|ABI provide drift|abipkg" "$needed|NEEDED miss|neededpkg"; do
            arch=${pair%%|*}
            rest=${pair#*|}
            what=${rest%%|*}
            subject=${rest##*|}
            run_engine "$ws" --install-decide force "$arch"
            [ "$FIXTURE_RC" = 1 ] || fail "force must not bypass the $what gate (rc 1, §E.3), got $FIXTURE_RC: $FIXTURE_OUTPUT"
            rows=$(printf '%s\n' "$FIXTURE_OUTPUT" | rows_only)
            printf '%s\n' "$rows" | awk -v s="$subject" '$1 == s && $2 == "refuse" { found = 1 } END { exit !found }' \
                || fail "force must not bypass the $what gate (a refuse row survives force):
$rows"
        done

        # ── noop (§E.3): `empty-list` under -Ua with zero eligible archives.
        # -Ua is force, so the empty plan is a noop, not a refusal (§B.6);
        # the row is printed through the same §E.2 framing.
        empty="$fixture/a/empty-ws"
        make_workspace "$empty" 1 auto low
        install_ws "$empty" "$db"
        mkdir -p "$empty/packages/idle"
        printf 'pkgname=idle\npkgver=1.0.0\npkgrel=1\narch=(any)\n' >"$empty/packages/idle/PKGBUILD"
        printf 'idle|packages/idle|git|\n' >>"$empty/config/topology.conf"
        run_engine "$empty" -Ua --dry-run --state-dir "$fixture/a/state" --config "$empty/pacman.conf"
        [ "$FIXTURE_RC" = 0 ] || fail "an empty -Ua plan is a noop, not a failure (§E.5), got $FIXTURE_RC: $FIXTURE_OUTPUT"
        assert_row "$(printf '%s\n' "$FIXTURE_OUTPUT" | rows_only)" - noop 'empty-list' "noop empty-list under -Ua (§E.3)"

        # ── the seam touches nothing (§D.1): every stub log above is still
        # empty (the -S park run below uses its own log paths)
        [ ! -s "$fixture/a/pacman.log" ] || fail "--install-decide touched pacman (§D.1):" "$fixture/a/pacman.log"
        [ ! -s "$fixture/a/sudo.log" ] || fail "--install-decide escalated through sudo (§D.1):" "$fixture/a/sudo.log"
        [ ! -s "$fixture/a/spawn.log" ] || fail "--install-decide ran makepkg (§D.1):" "$fixture/a/spawn.log"

        # ── usage errors are rc 2 and name the argument (§D.1/§E.5)
        run_engine "$ws" --install-decide bogus "$one"
        [ "$FIXTURE_RC" = 2 ] || fail "an unknown mode is rc 2 (§E.5), got $FIXTURE_RC"
        vgrep "$FIXTURE_OUTPUT" -F "unknown mode 'bogus'" >/dev/null \
            || fail "the mode refusal must name the argument: $FIXTURE_OUTPUT"
        run_engine "$ws" --install-decide checked "$ws/packages/one/absent.pkg.tar.zst"
        [ "$FIXTURE_RC" = 2 ] || fail "a malformed archive argument is rc 2 (§E.5), got $FIXTURE_RC"
        vgrep "$FIXTURE_OUTPUT" -F "malformed archive argument" >/dev/null \
            || fail "the archive refusal must name the argument: $FIXTURE_OUTPUT"
        run_engine "$ws" --install-decide
        [ "$FIXTURE_RC" = 2 ] || fail "an empty argument list is rc 2 (§E.5), got $FIXTURE_RC"

        # ── parked (§E.3): the run-record park row of an -S install refusal.
        # A decision-row `parked` needs DecisionContext.parks, which no
        # production caller populates (§D.1's fixed seam shape cannot express
        # a park), so the park is asserted where it is observable: the row
        # records it, and the parked position never builds or installs.
        park_ws="$fixture/a/park-ws"
        park_db="$fixture/a/park-db"
        make_workspace "$park_ws" 2 auto low
        install_ws "$park_ws" "$park_db"
        mkdir -p "$park_db"
        add_package "$park_ws" provider "$gsa_meta_any" git
        add_package "$park_ws" consumer "$gsa_meta_any" git
        set_topology_record "$park_ws" consumer git provider
        printf 'CFLAGS+=" -fprofile-generate=/tmp/p"\n' >>"$park_ws/packages/provider/PKGBUILD"
        export GSA_FAKE_SPAWN_LOG="$fixture/a/park-spawn.log"
        export GSA_FAKE_PACMAN_LOG="$fixture/a/park-pacman.log"
        export GSA_FAKE_SUDO_LOG="$fixture/a/park-sudo.log"
        export GSA_FAKE_PGO_PACKAGE=provider
        : >"$GSA_FAKE_SPAWN_LOG"
        : >"$GSA_FAKE_PACMAN_LOG"
        run_engine "$park_ws" -S --state-dir "$fixture/a/park-state" --config "$park_ws/pacman.conf" provider consumer
        rr2_body <<<"$FIXTURE_OUTPUT" >/dev/null \
            || fail "the -S park run emitted no complete run record: $FIXTURE_OUTPUT"
        [ "$(rr2_outcome consumer status <<<"$FIXTURE_OUTPUT")" = "parked" ] \
            || fail "the consumer of a refused install must park (§E.3): $FIXTURE_OUTPUT"
        [ "$(rr2_outcome consumer reason <<<"$FIXTURE_OUTPUT")" = "waits-on-failed" ] \
            || fail "the park row must carry waits-on-failed (§H.3): $FIXTURE_OUTPUT"
        if grep -q '^SPAWN consumer ' "$GSA_FAKE_SPAWN_LOG"; then
            fail "a parked consumer must never compile (install-before-dependents, rule 11):" "$GSA_FAKE_SPAWN_LOG"
        fi
        [ "$(txn_count "$GSA_FAKE_PACMAN_LOG")" = 0 ] \
            || fail "a parked plan transacts nothing (rule 25(h)):" "$GSA_FAKE_PACMAN_LOG"

        # ── self-explaining refusal (§H.2 amendment (a), 2026-10-14): a
        # shrunken split set refuses through its OWN rows (partial-set) and
        # must never synthesize a phantom `empty-list` row — `empty-list`
        # belongs to a genuinely empty candidate plan (the `-Ua` noop above).
        # (Pinned at cutover after a mutation probe showed the fix was
        # uncovered: collapsing the phantom row is what keeps the strict
        # format: 2 grammar — the extra row's `-` subject is not in `order`.)
        shrink="$fixture/a/shrink-ws"
        make_workspace "$shrink" 1 auto low
        install_ws "$shrink" "$db"
        add_package "$shrink" split "$gsa_meta_any" git
        printf 'pkgbase = split\npkgname = split\npkgname = split-libs\npkgver = 1.0.0\npkgrel = 1\narch = any\n' \
            >"$shrink/packages/split/.SRCINFO"
        stage="$fixture/a/shrink-stage"
        stage_pkginfo "$stage" split split 1.0.0-1 0
        make_archive "$shrink/packages/split/split-1.0.0-1-any.pkg.tar.zst" "$stage"
        export GSA_FAKE_PACMAN_LOG="$fixture/a/shrink-pacman.log"
        export GSA_FAKE_SUDO_LOG="$fixture/a/shrink-sudo.log"
        : >"$GSA_FAKE_PACMAN_LOG"
        : >"$GSA_FAKE_SUDO_LOG"
        run_engine "$shrink" -U --state-dir "$fixture/a/shrink-state" --config "$shrink/pacman.conf" split
        [ "$FIXTURE_RC" = 3 ] || fail "a shrunken split set must refuse rc 3 (§G.1), got $FIXTURE_RC: $FIXTURE_OUTPUT"
        rr2_body <<<"$FIXTURE_OUTPUT" >/dev/null \
            || fail "the self-explaining refusal record must parse strict format: 2 (§H.2): $FIXTURE_OUTPUT"
        grep < <(record_section plan) -Eq '^split refused partial-set ' \
            || fail "the plan must record the partial-set refusal (§H.2): $FIXTURE_OUTPUT"
        if grep -q 'empty-list' <<<"$FIXTURE_OUTPUT"; then
            fail "a self-explaining refusal must never synthesize an empty-list row (§H.2 amendment (a)): $FIXTURE_OUTPUT"
        fi
        [ "$(rr2_outcome split status <<<"$FIXTURE_OUTPUT")" = never-started ] \
            || fail "the refused subject is never-started (§H.3): $FIXTURE_OUTPUT"
        [ "$(rr2_continuation remaining <<<"$FIXTURE_OUTPUT")" = split ] \
            || fail "the refused subject stays in remaining: (§H.2): $FIXTURE_OUTPUT"
        [ "$(txn_count "$GSA_FAKE_PACMAN_LOG")" = 0 ] \
            || fail "a self-explaining refusal transacts nothing (rule 25(h)):" "$GSA_FAKE_PACMAN_LOG"
    )
fi

if want b; then
    # ─── 2. -S installs before consumers compile (rule 11, §B.4) ───────────
    (
        set -euo pipefail
        ws="$fixture/b/ws"
        db="$fixture/b/db"
        make_workspace "$ws" 2 auto low
        install_ws "$ws" "$db"
        mkdir -p "$db"
        add_package "$ws" lib "$gsa_meta_any" git
        add_package "$ws" app "$gsa_meta_any" git
        add_package "$ws" tool "$gsa_meta_any" git
        add_package "$ws" solo "$gsa_meta_any" git
        set_topology_record "$ws" app git lib
        set_topology_record "$ws" tool git app
        edges="$fixture/b/edges"
        printf 'app lib\ntool app\n' >"$edges"
        export GSA_FAKE_SPAWN_LOG="$fixture/b/spawn.log"
        export GSA_FAKE_PACMAN_LOG="$fixture/b/pacman.log"
        export GSA_FAKE_SUDO_LOG="$fixture/b/sudo.log"
        : >"$GSA_FAKE_SPAWN_LOG"
        : >"$GSA_FAKE_PACMAN_LOG"

        run_engine "$ws" -S --state-dir "$fixture/b/state" --config "$ws/pacman.conf" lib app tool solo
        {
            echo "$FIXTURE_OUTPUT"
        } >"$fixture/b/output.txt"

        rr2_body <<<"$FIXTURE_OUTPUT" >/dev/null \
            || fail "the -S run emitted no complete run record:" "$fixture/b/output.txt"
        [ "$FIXTURE_RC" = 0 ] || fail "-S install run rc=$FIXTURE_RC, want 0 (§G.1):" "$fixture/b/output.txt"
        [ "$FIXTURE_RC" = "$(rr2_scalar rc <<<"$FIXTURE_OUTPUT")" ] \
            || fail "the record's rc scalar disagrees with the process exit code:" "$fixture/b/output.txt"
        [ "$(rr2_scalar outcome <<<"$FIXTURE_OUTPUT")" = "success" ] \
            || fail "a clean -S run must record outcome 'success':" "$fixture/b/output.txt"

        # every package planned as build-install and built+installed clean
        for pkg in lib app tool solo; do
            [ "$(rr2_plan "$pkg" plan <<<"$FIXTURE_OUTPUT")" = "build-install" ] \
                || fail "-S must plan $pkg as build-install (§B.4):" "$fixture/b/output.txt"
            [ "$(rr2_outcome "$pkg" status <<<"$FIXTURE_OUTPUT")" = "succeeded" ] \
                || fail "$pkg did not succeed in the -S run:" "$fixture/b/output.txt"
        done

        # the record's order is a topological order of the fixture's edges
        order=$(rr2_scalar order <<<"$FIXTURE_OUTPUT")
        awk -v order="$order" '
            BEGIN { n = split(order, ids, " "); for (i = 1; i <= n; i++) pos[ids[i]] = i }
            pos[$2] && pos[$1] && !(pos[$2] < pos[$1]) {
                printf("order %s is not topological: %s must precede %s\n", order, $2, $1) > "/dev/stderr"
                bad = 1
            }
            END { exit bad }' "$edges" \
            || fail "the run-record order violates the fixture topology:" "$fixture/b/output.txt"

        # install-before-dependents, proved from the stub clocks: for every
        # build-order edge (consumer prereq) the prereq's pacman -U ENDS
        # before the consumer's makepkg SPAWNs
        while read -r consumer prereq; do
            install_end=$(txn_end_for "$prereq-1.0.0-1-any.pkg.tar.zst" "$GSA_FAKE_PACMAN_LOG")
            consumer_spawn=$(spawn_ts "$consumer" "$GSA_FAKE_SPAWN_LOG")
            [ -n "$install_end" ] || fail "no transaction installed $prereq before $consumer compiled:" "$GSA_FAKE_PACMAN_LOG"
            [ -n "$consumer_spawn" ] || fail "consumer $consumer never compiled:" "$GSA_FAKE_SPAWN_LOG"
            [ "$install_end" -lt "$consumer_spawn" ] \
                || fail "$consumer compiled before $prereq's install landed (rule 11): install ended $install_end, spawn $consumer_spawn" "$GSA_FAKE_PACMAN_LOG"
        done <"$edges"

        # one transaction per installed package (derived from the record's
        # succeeded rows), each naming its package's archive
        expected=$(rr2_outcome_rows <<<"$FIXTURE_OUTPUT" | awk '$2 == "succeeded" { n++ } END { print n + 0 }')
        [ "$(txn_count "$GSA_FAKE_PACMAN_LOG")" = "$expected" ] \
            || fail "want $expected pacman -U transactions (one per installed package), got $(txn_count "$GSA_FAKE_PACMAN_LOG"):" "$GSA_FAKE_PACMAN_LOG"
        for pkg in lib app tool solo; do
            txn_argv "$GSA_FAKE_PACMAN_LOG" | grep -F -- "/packages/$pkg/$pkg-" >/dev/null \
                || fail "no transaction named $pkg's archive:" "$GSA_FAKE_PACMAN_LOG"
        done
    )
fi

if want c; then
    # ─── 3. exactly one pacman -U at a time (§K.3) ─────────────────────────
    (
        set -euo pipefail
        ws="$fixture/c/ws"
        db="$fixture/c/db"
        make_workspace "$ws" 2 auto low
        install_ws "$ws" "$db"
        mkdir -p "$db"
        for pkg in p1 p2 p3 p4; do
            add_package "$ws" "$pkg" "$gsa_meta_any" git
        done
        export GSA_FAKE_SPAWN_LOG="$fixture/c/spawn.log"
        export GSA_FAKE_PACMAN_LOG="$fixture/c/pacman.log"
        export GSA_FAKE_SUDO_LOG="$fixture/c/sudo.log"
        # linger inside each transaction so two lanes COULD overlap were the
        # transactions not serialized
        export GSA_FAKE_PACMAN_SLEEP=0.4
        : >"$GSA_FAKE_SPAWN_LOG"
        : >"$GSA_FAKE_PACMAN_LOG"

        run_engine "$ws" -S --state-dir "$fixture/c/state" --config "$ws/pacman.conf" p1 p2 p3 p4 -- --overwrite '*'
        {
            echo "$FIXTURE_OUTPUT"
        } >"$fixture/c/output.txt"

        rr2_body <<<"$FIXTURE_OUTPUT" >/dev/null \
            || fail "the -S run emitted no complete run record:" "$fixture/c/output.txt"
        [ "$FIXTURE_RC" = 0 ] || fail "the serialization run rc=$FIXTURE_RC, want 0:" "$fixture/c/output.txt"

        # no two transaction windows overlap; there were transactions to
        # serialize (one per installed package — derived from the record)
        assert_txn_serial "$GSA_FAKE_PACMAN_LOG" "parallel lanes"
        expected=$(rr2_outcome_rows <<<"$FIXTURE_OUTPUT" | awk '$2 == "succeeded" { n++ } END { print n + 0 }')
        [ "$(txn_count "$GSA_FAKE_PACMAN_LOG")" = "$expected" ] \
            || fail "want $expected transactions (one per installed package), got $(txn_count "$GSA_FAKE_PACMAN_LOG"):" "$GSA_FAKE_PACMAN_LOG"

        # every TRANSACTION argv is the §K.3 shape and carries the §B.1
        # `-- <pacman args…>` passthrough verbatim, BEFORE the archives. The
        # toolchain preflight's read-only `pacman -Q rust-git` probe runs on
        # every build-family run (2026-10-14, the probe-gating decision) and
        # is no transaction.
        while read -r argv; do
            case "$argv" in
            "-U --noconfirm --ask 4"*) ;;
            "-Q rust-git") continue ;;
            *) fail "transaction argv is not the §K.3 shape (-U --noconfirm --ask 4 …): $argv" "$GSA_FAKE_PACMAN_LOG" ;;
            esac
            vgrep "$argv" -q -- '--overwrite \* .*\.pkg\.tar\.zst' \
                || fail "the -- passthrough must land before the archives (§B.1): $argv" "$GSA_FAKE_PACMAN_LOG"
        done <<<"$(txn_argv "$GSA_FAKE_PACMAN_LOG")"
    )
fi

if want d; then
    # ─── 4. force bypasses the same-version skip (§B.6 f / §E) ─────────────
    (
        set -euo pipefail
        ws="$fixture/d/ws"
        db="$fixture/d/db"
        make_workspace "$ws" 1 auto low
        install_ws "$ws" "$db"
        mkdir -p "$db"
        ver="1.2.3-4"
        canon="7:$ver"
        add_package "$ws" pkg "$gsa_meta_any" git
        stage="$fixture/d/stage"
        stage_pkginfo "$stage" pkg pkg "$ver" 7
        make_archive "$ws/packages/pkg/pkg-$ver-any.pkg.tar.zst" "$stage"
        pkgdir=$(db_install "$db" pkg "$canon")
        touch "$pkgdir" # install date now: not older than the archive → already-current
        export GSA_FAKE_PACMAN_LOG="$fixture/d/pacman.log"
        export GSA_FAKE_SUDO_LOG="$fixture/d/sudo.log"
        export GSA_FAKE_SPAWN_LOG="$fixture/d/spawn.log"
        archive="$ws/packages/pkg/pkg-$ver-any.pkg.tar.zst"

        # seam pair (§D.1/§E.5)
        run_engine "$ws" --install-decide checked "$archive"
        assert_row "$(printf '%s\n' "$FIXTURE_OUTPUT" | rows_only)" pkg skip "already-current $canon" "checked skip at the seam"
        run_engine "$ws" --install-decide force "$archive"
        assert_row "$(printf '%s\n' "$FIXTURE_OUTPUT" | rows_only)" pkg install 'ok' "force install at the seam (§B.6 f)"

        # run pair: checked skips and transacts NOTHING; force installs with
        # exactly one transaction
        : >"$GSA_FAKE_PACMAN_LOG"
        run_engine "$ws" -U --state-dir "$fixture/d/state" --config "$ws/pacman.conf" "$archive"
        {
            echo "$FIXTURE_OUTPUT"
        } >"$fixture/d/checked.txt"
        [ "$FIXTURE_RC" = 0 ] || fail "a skip-only -U run is rc 0 (§G.1), got $FIXTURE_RC:" "$fixture/d/checked.txt"
        record_section plan | awk -v want="pkg skip already-current $canon" '
            $0 == want { found = 1 } END { exit !found }' \
            || fail "the -U record must plan the same-version skip (§E.3):" "$fixture/d/checked.txt"
        [ "$(txn_count "$GSA_FAKE_PACMAN_LOG")" = 0 ] \
            || fail "a skipped package must not transact:" "$GSA_FAKE_PACMAN_LOG"

        : >"$GSA_FAKE_PACMAN_LOG"
        run_engine "$ws" -Uf --state-dir "$fixture/d/state" --config "$ws/pacman.conf" "$archive"
        {
            echo "$FIXTURE_OUTPUT"
        } >"$fixture/d/force.txt"
        [ "$FIXTURE_RC" = 0 ] || fail "a forced -U run is rc 0 (§G.1), got $FIXTURE_RC:" "$fixture/d/force.txt"
        record_section plan | awk '$0 == "pkg install ok" { found = 1 } END { exit !found }' \
            || fail "the -Uf record must plan the install (§E.3):" "$fixture/d/force.txt"
        [ "$(txn_count "$GSA_FAKE_PACMAN_LOG")" = 1 ] \
            || fail "force must run exactly one pacman -U, got $(txn_count "$GSA_FAKE_PACMAN_LOG"):" "$GSA_FAKE_PACMAN_LOG"
        txn_argv "$GSA_FAKE_PACMAN_LOG" | grep -F -- "$archive" >/dev/null \
            || fail "the forced transaction must name the archive:" "$GSA_FAKE_PACMAN_LOG"
    )
fi

if want e; then
    # ─── 5. install refusal = rc 3, pacman-free end to end (rule 25(h)) ────
    (
        set -euo pipefail
        ver="1.2.3-4"

        # ── (i) -U: the refusing plan reaches neither pacman nor sudo nor
        # the registration — the conf is byte-identical afterwards
        ws="$fixture/e/ws"
        db="$fixture/e/db"
        make_workspace "$ws" 1 auto low
        install_ws "$ws" "$db"
        mkdir -p "$db"
        mkdir -p "$ws/packages/pgopkg"
        stage="$fixture/e/stage"
        stage_pkginfo "$stage" pgopkg pgopkg "$ver" 7
        mkdir -p "$stage/usr/lib"
        printf '# baked /home/u/build/train.gcda\n' >"$stage/usr/lib/libp.so"
        printf '# baked /home/u/build/train2.gcda\n' >"$stage/usr/lib/libq.so"
        make_archive "$ws/packages/pgopkg/pgopkg-$ver-any.pkg.tar.zst" "$stage"
        printf 'pkgname=pgopkg\npkgver=1.2.3\npkgrel=4\narch=(any)\nCFLAGS+=" -fprofile-generate=/tmp/p"\n' \
            >"$ws/packages/pgopkg/PKGBUILD"
        export GSA_FAKE_PACMAN_LOG="$fixture/e/pacman.log"
        export GSA_FAKE_SUDO_LOG="$fixture/e/sudo.log"
        export GSA_FAKE_SPAWN_LOG="$fixture/e/spawn.log"
        : >"$GSA_FAKE_PACMAN_LOG"
        : >"$GSA_FAKE_SUDO_LOG"
        cp "$ws/pacman.conf" "$fixture/e/conf.pre"

        run_engine "$ws" -U --state-dir "$fixture/e/state" --config "$ws/pacman.conf" \
            "$ws/packages/pgopkg/pgopkg-$ver-any.pkg.tar.zst"
        {
            echo "$FIXTURE_OUTPUT"
        } >"$fixture/e/output.txt"
        [ "$FIXTURE_RC" = 3 ] || fail "an install refusal is rc 3 (§G.1), got $FIXTURE_RC:" "$fixture/e/output.txt"
        [ "$(record_scalar rc)" = 3 ] || fail "the record's rc scalar must be 3 for a refusal:" "$fixture/e/output.txt"
        [ "$(record_scalar outcome)" = "refused" ] || fail "the record must record outcome 'refused':" "$fixture/e/output.txt"
        grep < <(record_section outcome) -q ' install-refused pgo-' \
            || fail "the refusal rows must carry install-refused reasons (§H.3):" "$fixture/e/output.txt"
        # Two PGO hits = two §E.2 decision rows but ONE record row per
        # SUBJECT (§H.2; the collapse the strict parser above enforces):
        # both hit members survive in the joined reason.
        [ "$(record_section plan | wc -l)" = 1 ] \
            || fail "a multi-row candidate must collapse to one plan row (§H.2): $(record_section plan)" "$fixture/e/output.txt"
        [ "$(record_section outcome | wc -l)" = 1 ] \
            || fail "a multi-row candidate must collapse to one outcome row (§H.2): $(record_section outcome)" "$fixture/e/output.txt"
        plan_row=$(record_section plan)
        case $plan_row in
        *libp.so*libq.so*) ;;
        *) fail "the collapsed plan row must keep both PGO hit reasons: $plan_row" "$fixture/e/output.txt" ;;
        esac
        [ "$(txn_count "$GSA_FAKE_PACMAN_LOG")" = 0 ] \
            || fail "a refusing plan is pacman-free end to end (rule 25(h)):" "$GSA_FAKE_PACMAN_LOG"
        [ ! -s "$GSA_FAKE_SUDO_LOG" ] \
            || fail "a refusing plan must not even probe sudo (refusal precedes preflight):" "$GSA_FAKE_SUDO_LOG"
        cmp -s "$ws/pacman.conf" "$fixture/e/conf.pre" \
            || fail "a refusing plan must never rewrite the IgnorePkg closure:" "$ws/pacman.conf"

        # ── (ii) -S: a build that SUCCEEDED still transacts nothing when its
        # install refuses (NEEDED gate), the run exits 3 (§G.1 refusal class),
        # and the consumer cone never compiles
        ws2="$fixture/e/ws2"
        db2="$fixture/e/db2"
        make_workspace "$ws2" 2 auto low
        install_ws "$ws2" "$db2"
        mkdir -p "$db2"
        add_package "$ws2" provider "$gsa_meta_any" git
        add_package "$ws2" consumer "$gsa_meta_any" git
        set_topology_record "$ws2" consumer git provider
        write_elf64_needed "$fixture/e/probe.elf" libmissing.so.9
        export GSA_FAKE_SPAWN_LOG="$fixture/e/spawn2.log"
        export GSA_FAKE_PACMAN_LOG="$fixture/e/pacman2.log"
        export GSA_FAKE_SUDO_LOG="$fixture/e/sudo2.log"
        export GSA_FAKE_ELF_PACKAGE=provider
        export GSA_FAKE_ELF_SRC="$fixture/e/probe.elf"
        : >"$GSA_FAKE_SPAWN_LOG"
        : >"$GSA_FAKE_PACMAN_LOG"

        run_engine "$ws2" -S --state-dir "$fixture/e/state2" --config "$ws2/pacman.conf" provider consumer
        {
            echo "$FIXTURE_OUTPUT"
        } >"$fixture/e/output2.txt"
        rr2_body <<<"$FIXTURE_OUTPUT" >/dev/null \
            || fail "the refusing -S run emitted no complete run record:" "$fixture/e/output2.txt"
        [ "$FIXTURE_RC" = 3 ] || fail "an -S install refusal is rc 3 (§G.1), got $FIXTURE_RC:" "$fixture/e/output2.txt"
        [ "$FIXTURE_RC" = "$(rr2_scalar rc <<<"$FIXTURE_OUTPUT")" ] \
            || fail "the record's rc scalar disagrees with the process exit code:" "$fixture/e/output2.txt"
        grep < <(rr2_outcome provider reason <<<"$FIXTURE_OUTPUT") -q '^install-refused needed ' \
            || fail "the refusing row must name the NEEDED gate (§H.3):" "$fixture/e/output2.txt"
        [ "$(txn_count "$GSA_FAKE_PACMAN_LOG")" = 0 ] \
            || fail "a refusing -S plan is pacman-free (rule 25(h)):" "$GSA_FAKE_PACMAN_LOG"
        if grep -q '^SPAWN consumer ' "$GSA_FAKE_SPAWN_LOG"; then
            fail "a consumer of a refused install must never compile (rule 25(h)):" "$GSA_FAKE_SPAWN_LOG"
        fi
    )
fi

if want f; then
    # ─── 6. db.lck is never deleted (rule 23, §K.3) ────────────────────────
    (
        set -euo pipefail
        ws="$fixture/f/ws"
        db="$fixture/f/db"
        make_workspace "$ws" 1 auto low
        install_ws "$ws" "$db"
        mkdir -p "$db"
        export GSA_FAKE_PACMAN_LOG="$fixture/f/pacman.log"
        export GSA_FAKE_SUDO_LOG="$fixture/f/sudo.log"
        export GSA_FAKE_SPAWN_LOG="$fixture/f/spawn.log"
        : >"$GSA_FAKE_PACMAN_LOG"

        # a STALE lock (present, no live holder): the registration announces
        # it, proceeds, and never touches the file
        printf 'fixture lock marker\n' >"$db/db.lck"
        cp "$db/db.lck" "$fixture/f/db.lck.pre"
        run_engine "$ws" --install-register "$ws/pacman.conf" fixture alpha beta
        {
            echo "$FIXTURE_OUTPUT"
        } >"$fixture/f/output.txt"
        [ "$FIXTURE_RC" = 0 ] || fail "the registration seam is rc 0 (§D.1), got $FIXTURE_RC:" "$fixture/f/output.txt"
        vgrep "$FIXTURE_OUTPUT" -F 'without touching it' >/dev/null \
            || fail "a stale db.lck must be announced as never touched (rule 23):" "$fixture/f/output.txt"
        cmp -s "$db/db.lck" "$fixture/f/db.lck.pre" \
            || fail "the registration deleted or rewrote db.lck (it must never be deleted):" "$db/db.lck"
        grep -q '^IgnorePkg = alpha beta$' "$ws/pacman.conf" \
            || fail "the registration must still land beside the untouched lock:" "$ws/pacman.conf"
    )
fi

if want g; then
    # ─── 7. interrupt mid-install: no half-registered IgnorePkg (§I.3/§K.3) ─
    (
        set -euo pipefail
        ws="$fixture/g/ws"
        db="$fixture/g/db"
        make_workspace "$ws" 1 auto low
        install_ws "$ws" "$db"
        mkdir -p "$db"
        ver="1.2.3-4"
        # two archives whose names do not collapse (pkgbase ≠ pkgname): the
        # registration must land ALL FOUR names or none (atomic rewrite,
        # never a subset)
        mkdir -p "$ws/packages/alpha" "$ws/packages/beta"
        stage="$fixture/g/stage"
        stage_pkginfo "$stage" alpha alpha-out "$ver" 7
        make_archive "$ws/packages/alpha/alpha-$ver-any.pkg.tar.zst" "$stage"
        stage_pkginfo "$stage" beta beta-out "$ver" 7
        make_archive "$ws/packages/beta/beta-$ver-any.pkg.tar.zst" "$stage"
        expected_names="$fixture/g/expected-names"
        printf 'alpha\nalpha-out\nbeta\nbeta-out\n' | sort >"$expected_names"
        export GSA_FAKE_PACMAN_LOG="$fixture/g/pacman.log"
        export GSA_FAKE_SUDO_LOG="$fixture/g/sudo.log"
        export GSA_FAKE_SPAWN_LOG="$fixture/g/spawn.log"
        : >"$GSA_FAKE_PACMAN_LOG"
        # linger inside the transaction so the signal lands mid-`pacman -U`
        export GSA_FAKE_PACMAN_SLEEP=20

        # the engine needs one SIGINT mid-transaction; run_engine performs the
        # invocation while a wrapper records the engine pid (exec keeps it)
        pidfile="$fixture/g/engine.pid"
        wrap="$fixture/g/gsa-wrap"
        cat >"$wrap" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$\$" > "\${GSA_FAKE_ENGINE_PID:?}"
exec "$GSA_TEST_GSA_BIN" "\$@"
EOF
        chmod +x "$wrap"
        (
            for _ in $(seq 1 400); do [ -s "$pidfile" ] && break; sleep 0.025; done
            [ -s "$pidfile" ] || exit 0
            for _ in $(seq 1 800); do
                grep -q '^TXN-START ' "$GSA_FAKE_PACMAN_LOG" 2>/dev/null && break
                sleep 0.025
            done
            # the engine is root under W5 (run_engine's sudo) — signal it
            # through the host's REAL sudo, never the PATH stub
            /usr/bin/sudo -n kill -INT "$(cat "$pidfile")" 2>/dev/null || true
        ) &
        watcher=$!
        GSA_TEST_GSA_BIN="$wrap" GSA_FAKE_ENGINE_PID="$pidfile" run_engine "$ws" -Uf \
            --state-dir "$fixture/g/state" --config "$ws/pacman.conf" \
            "$ws/packages/alpha/alpha-$ver-any.pkg.tar.zst" "$ws/packages/beta/beta-$ver-any.pkg.tar.zst"
        kill "$watcher" 2>/dev/null || true
        wait "$watcher" 2>/dev/null || true
        {
            echo "$FIXTURE_OUTPUT"
        } >"$fixture/g/output.txt"

        # the signal landed mid-transaction (the stub had opened one)
        grep -q '^TXN-START ' "$GSA_FAKE_PACMAN_LOG" \
            || fail "the interrupt did not land mid-install (no transaction started):" "$GSA_FAKE_PACMAN_LOG"

        # §I.3: rc 130 with the FULL record emitted first (inline fields: a
        # -U record renders `lanes: -`, which rr2_* rejects)
        [ "$FIXTURE_RC" = 130 ] || fail "an interrupted run exits 130 (§G.1), got $FIXTURE_RC:" "$fixture/g/output.txt"
        [ "$(record_scalar rc)" = 130 ] || fail "the record's rc scalar must be 130:" "$fixture/g/output.txt"
        [ "$(record_scalar outcome)" = "interrupted" ] || fail "the record must record outcome 'interrupted':" "$fixture/g/output.txt"
        grep -q '^--- run record begin ---$' "$fixture/g/output.txt" \
            && grep -q '^--- run record end ---$' "$fixture/g/output.txt" \
            || fail "the interrupted run must emit the full record (§I.3):" "$fixture/g/output.txt"
        grep < <(record_section outcome) -q '^alpha interrupted 130 ' \
            || fail "the interrupted install rows must carry a signal lane code (§F.1):" "$fixture/g/output.txt"

        # no half-registered IgnorePkg: the closure covers EVERY accepted
        # name (derived from the staged .PKGINFOs — all or nothing), the conf
        # parses, and no temp name survives the atomic rewrite
        closure="$fixture/g/closure"
        sed -n 's/^IgnorePkg = //p' "$ws/pacman.conf" | tr ' ' '\n' | sed '/^$/d' | sort >"$closure"
        missing=$(comm -23 "$expected_names" "$closure" | tr '\n' ' ' | sed 's/ $//')
        [ -z "$missing" ] \
            || fail "the interrupt left a half-registered IgnorePkg closure (missing: $missing):" "$ws/pacman.conf"
        grep -q '^\[options\]$' "$ws/pacman.conf" \
            || fail "the rewritten conf lost its [options] section:" "$ws/pacman.conf"
        if grep < <(find "$ws" -maxdepth 1 -name '.gsa-ignorepkg.tmp.*' -print -quit) -q .; then
            fail "the atomic registration left a temp name beside the conf:" "$ws"
        fi
        if ! ls "$ws"/pacman.conf.bak-* >/dev/null 2>&1; then
            fail "the registration must leave its dated pre-image backup:" "$ws"
        fi
    )
fi

printf 'gsa-install-v2 fixture: PASS\n'
