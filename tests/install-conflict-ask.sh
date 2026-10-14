#!/usr/bin/env bash
set -euo pipefail

# The install contract behind the stock→house swap (2026-10-04 hardening):
# the `-U`/`-Ua` install pipelines run ONE pacman transaction as
# `pacman -U --noconfirm --ask 4 …` — and `--ask 4` is load-bearing: bit
# (1 << 2) is ALPM_QUESTION_CONFLICT_PKG, so every "remove conflicting
# package?" prompt (the stock package standing where the -git build must go)
# is force-YESed instead of hanging a lane with no tty. Drop the mask and the
# swap silently stops happening; reorder or interleave other flags and the
# contract nobody can grep for breaks.
#
# Pinned here (stub oracle: every pacman argv lands in GSA_FAKE_PACMAN_LOG):
#   A. the `-U` transaction is exactly `pacman -U --noconfirm --ask 4 --config
#      <conf> <archive>` — `--config` is the engine's own pacman global
#      (§B.8) and the only flag beyond the mask (DEVIATION 3);
#   B. `-Ua -- --overwrite '*'` forwards the extra args AFTER those flags in
#      the SAME command (`-U --noconfirm --ask 4 --config <conf> --overwrite *
#      <archives>`), so they can never displace the conflict mask (§B.1 `--`);
#   C. plan refusal rows (`--install-decide` and the `-U` plan entries: empty
#      lists, PGO-instrumented payloads) never reach the pacman stub — the
#      auto-YES must not fire for a transaction that was refused (§E.1);
#   D. semantic pin: /usr/include/alpm.h still declares
#      ALPM_QUESTION_CONFLICT_PKG = (1 << 2). If the enum ever reorders, this
#      fails and forces re-deriving the mask (skipped, loudly, when alpm.h is
#      absent on a host).
#
# Flip notes (docs/gsa-fixture-migration.md inventory row
# `tests/install-conflict-ask.sh`, phase 3): argv map fish `-i p1` →
# `gsa -U p1`, `-ia [--overwrite '*']` → `gsa -Ua [-- --overwrite '*']`
# (§B.6), fish `--install-decide` → the hidden gsa seam
# `gsa --install-decide <checked|force> <archive…>` (§D.1). R-5 (§6): the two
# tab plan_row equalities (old :151-152, :176-177) retire as FRAMING and their
# row meanings re-pin as `(pkgbase, decision, reason-key)` triples through
# rr2_decisions (§E.2), detail after the reason key stripped (§7). The one
# prose pin (old :188) becomes record-derived rows (§H.3). §6's R-1/R-2
# classes (fish source greps, the format:1 row grammar) have no site in this
# fixture.
#
# DEVIATION 1 (inventory row "rc 0/1/2 (§E.5)" vs the seam): `refuse
# empty-list` is not expressible at `--install-decide` itself — the seam's
# grammar is `<checked|force> <archive…>` (§D.1): an empty argument list is
# §E.5 bad usage (rc 2, no rows) and a zero-byte "archive" refuses
# `discover-failed` (§E.3 — real archives are required everywhere). The
# `refuse empty-list` meaning re-pins at the `-U` plan entry (same §E.2
# grammar: checked `-U --dry-run` prints `refuse empty-list`, `-Ua --dry-run`
# prints `noop empty-list` — §B.6) and as the executed refusal's record row
# `install-refused empty-list`. The seam still pins all three §E.5 rc classes:
# 0 clean plan (A), 1 refusal rows (C2), 2 bad usage (C1).
# DEVIATION 2 (§H debt, tests/gsa-install-v2.sh convention): `-U`/`-Ua` run
# records extract INLINE (record_scalar/record_section) and are never fed to
# rr2_*. The shapes this once rested on are SUPERSEDED by the cutover's
# record conformance (`lanes: 0` never `-`, per-subject rows, duplicate-free
# `order` — contract §H.2 amendment (a), 2026-10-14, pinned in C3 below).
# DEVIATION 3 (transaction argv vs the old pin): the engine forwards its
# `--config` pacman global (§B.8) to the transaction — the one flag the old
# fish spelling (`pacman -U --noconfirm --ask 4 <archive>`, no extras) did not
# carry. The shape pins are now EXACT argv equalities over a per-argv stub
# log, so any flag reorder or interleave still fails; the mask order and the
# §B.1 "passthrough after the flags, before the archives" rule keep.
# DEVIATION 4 (C3b sudo): a `-Ua` refusal still passes the `sudo -n true`
# non-interactive preflight probe (§K.3) before its plan refuses, so the old
# "sudo log stays empty" pin keeps its strict form on the `-U` refusal paths
# (C1/C3a) and the `-Ua` path pins the behaviour itself: a refused
# transaction is never escalated (no `sudo … pacman`, zero pacman calls).
#
# Nothing here touches the real repository: the workspace is synthetic under
# $TMPDIR, engine state is redirected (`--state-dir`, never /var/lib/gsa), the
# IgnorePkg registration target is the fixture's own `--config` conf (never
# the host's /etc/pacman.conf), and pacman/sudo stay stubs.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-install-conflict-ask.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    printf 'install conflict-ask fixture: %s\n' "$1" >&2
    exit 1
}

# ─── The engine under test: built into the fixture tree (scratch only).
# GSA_TEST_GSA_BIN, when already set to an executable, is that engine (the
# rr-v2.bash run_engine convention) and the scratch build is skipped. ──────
if [ -z "${GSA_TEST_GSA_BIN:-}" ]; then
    cargo build --offline --quiet --target-dir "$fixture/cargo" -p gsa-cli \
        --manifest-path "$gsa_repo_root/Cargo.toml" ||
        fail "cannot build the gsa binary for the fixture"
    GSA_TEST_GSA_BIN="$fixture/cargo/debug/gsa"
fi
[ -x "$GSA_TEST_GSA_BIN" ] || fail "the engine under test is not executable: $GSA_TEST_GSA_BIN"
export GSA_TEST_ENGINE=gsa
export GSA_TEST_GSA_BIN

# ─── Inline oracle synthesis (§D.2: a stub lives in the fixture that gives it
# meaning; tests/gsa-install-v2.sh is the style model) ──────────────────────

# stage_pkginfo STAGE PKGBASE PKGNAME PKGVER — the staged `.PKGINFO` of one
# hand-built archive (PKGVER carries pkgrel, e.g. 1.0.0-1, as makepkg writes
# it).
stage_pkginfo() {
    local stage=$1 base=$2 name=$3 ver=$4
    mkdir -p "$stage"
    {
        printf 'pkgbase = %s\n' "$base"
        printf 'pkgname = %s\n' "$name"
        printf 'pkgver = %s\n' "$ver"
        printf 'arch = any\n'
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

# stage_archive OUT PKGBASE PKGNAME PKGVER — a REAL archive. The engine's
# install discovery reads each archive's own `.PKGINFO`, so a trivial empty
# file would refuse `discover-failed` before the scenario starts (§E.3).
stage_archive() {
    local stage
    stage=$(mktemp -d "$fixture/stage.XXXXXX")
    stage_pkginfo "$stage" "$2" "$3" "$4"
    make_archive "$1" "$stage"
}

# write_stub_pacman DIR — the transaction oracle: one BEGIN / argv / END
# triple per invocation, one argv per line (a split path shows up as a
# truncated argv line and a lost remainder).
write_stub_pacman() {
    cat >"$1/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -u
{
    printf 'BEGIN\n'
    for a in "$@"; do printf 'argv:%s\n' "$a"; done
    printf 'END\n'
} >>"${GSA_FAKE_PACMAN_LOG:?}"
exit 0
EOF
    chmod +x "$1/bin/pacman"
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

# write_stub_pacman_conf DIR DBROOT — `pacman-conf DBPath` answers the
# fixture's fabricated DB root, never the host's /var/lib/pacman.
write_stub_pacman_conf() {
    cat >"$1/bin/pacman-conf" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = DBPath ] && printf '%s\n' "$2"
exit 0
EOF
    chmod +x "$1/bin/pacman-conf"
}

# make_case_ws DIR — synthetic workspace + PATH stubs: argv-logging pacman,
# passthrough sudo and a pacman-conf DBPath oracle so nothing ever probes the
# host's real /var/lib/pacman.
make_case_ws() {
    local dir=$1
    make_workspace "$dir" 1 2 low
    add_package "$dir" p1 "$gsa_meta_any"
    mkdir -p "$dir/db/local"
    write_stub_pacman "$dir"
    write_stub_sudo "$dir"
    write_stub_pacman_conf "$dir" "$dir/db"
}

# run_install WS ARG... — an engine run through run_engine (rr-v2.bash) with
# the case's stubs on PATH; status in FIXTURE_RC, capture in FIXTURE_OUTPUT.
# Call sites spell the §B family argv themselves — including `--state-dir`
# and `--config`, which must never fall behind the `--` passthrough.
run_install() {
    local ws=$1
    shift
    export PATH="$ws/bin:$PATH"
    export GSA_FAKE_PACMAN_LOG="$ws/pacman.log"
    export GSA_FAKE_SUDO_LOG="$ws/sudo.log"
    run_engine "$ws" "$@"
}

# seam_run WS ARG... — the hidden `--install-decide` seam (§D.1) over the
# case's fabricated state. Its only legal subprocess is `pacman-conf DBPath`;
# pacman and sudo are FAIL-stubs that also log — a decision-only run that
# reaches one is caught twice (the log and the non-zero stub).
mkdir -p "$fixture/seam-bin" "$fixture/seam-db/local"
cat >"$fixture/seam-bin/pacman-conf" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = DBPath ] && printf '%s\n' "${GSA_FAKE_DB_PATH:?}"
exit 0
EOF
chmod +x "$fixture/seam-bin/pacman-conf"
for tool in pacman sudo; do
    cat >"$fixture/seam-bin/$tool" <<EOF
#!/usr/bin/env bash
printf 'UNEXPECTED $tool in a decision-only run: %s\n' "\$*" >>"$fixture/seam.log"
exit 99
EOF
    chmod +x "$fixture/seam-bin/$tool"
done

seam_run() {
    local ws=$1
    shift
    export PATH="$fixture/seam-bin:$PATH"
    export GSA_FAKE_DB_PATH="$ws/db"
    run_engine "$ws" "$@"
}

# txn_argv LOG — the argv of the ONE pacman transaction (any other count
# fails), one word per line.
txn_argv() {
    local log=$1 n
    n=$(grep -c '^BEGIN$' "$log" 2>/dev/null || true)
    [[ $n == 1 ]] ||
        fail "expected exactly one pacman transaction, log was: $(cat "$log" 2>/dev/null)"
    sed -n '/^BEGIN$/,/^END$/p' "$log" | sed -e '1d' -e '$d' -e 's/^argv://'
}

# assert_argv LABEL LOG WORD... — the transaction argv is EXACTLY these words
# in this order (DEVIATION 3: the §K.3 mask shape plus the engine's --config).
assert_argv() {
    local label=$1 log=$2
    shift 2
    local want got
    want=$(printf '%s\n' "$@")
    got=$(txn_argv "$log")
    [[ $got == "$want" ]] ||
        fail "$label: wrong pacman argv.
want:
$want
got:
$got
log: $(cat "$log")"
}

# decision_rows — the §E.2 decision rows of one engine capture: the leading
# rows only (the seam prints rows alone; a plan entry prints its rows before
# the prose and run-record spans), engine diagnostics dropped.
decision_rows() {
    awk '/^--- run record begin ---/ || /^Build run: / { exit } !/^gsa: / && NF { print }'
}

# assert_decisions LABEL RC — the §E.2 re-pin: $FIXTURE_OUTPUT's normalized
# (pkgbase, decision, reason-key) rows exactly as given on stdin, in plan
# order, plus the seam's rc contract (§E.5: 0 = no refuse row / 1 = >=1
# refuse row / 2 = bad usage and no rows).
assert_decisions() {
    local label=$1 rc=$2 want got
    want=$(cat)
    got=$(decision_rows <<<"$FIXTURE_OUTPUT" | rr2_decisions) ||
        fail "$label: unparsable §E.2 decision rows: $FIXTURE_OUTPUT"
    [[ $got == "$want" ]] ||
        fail "$label: wrong §E.2 decision rows (pkgbase decision reason-key, plan order).
want:
$want
got:
$got
output: $FIXTURE_OUTPUT"
    [[ $FIXTURE_RC == "$rc" ]] ||
        fail "$label: seam rc=$FIXTURE_RC, want $rc (§E.5): $FIXTURE_OUTPUT"
    if [[ $rc == 0 ]] && grep -q ' refuse ' <<<"$got"; then
        fail "$label: an rc 0 plan contains a refuse row (§E.5): $got"
    fi
    if [[ $rc == 1 ]] && ! grep -q ' refuse ' <<<"$got"; then
        fail "$label: an rc 1 plan has no refuse row (§E.5): $got"
    fi
    if [[ $rc == 2 && -n $got ]]; then
        fail "$label: an rc 2 bad-usage call printed decision rows (§E.5): $got"
    fi
}

# assert_rows LABEL — the §E.2 rows only, for a plan entry that is not the
# decision seam (a dry-run's rc is the run's `planned` class, §H/§G.1, not
# the seam's §E.5 mapping).
assert_rows() {
    local label=$1 want got
    want=$(cat)
    got=$(decision_rows <<<"$FIXTURE_OUTPUT" | rr2_decisions) ||
        fail "$label: unparsable §E.2 decision rows: $FIXTURE_OUTPUT"
    [[ $got == "$want" ]] ||
        fail "$label: wrong §E.2 decision rows (pkgbase decision reason-key, plan order).
want:
$want
got:
$got
output: $FIXTURE_OUTPUT"
}

# record_scalar KEY / record_section plan|outcome — fields of the machine
# block of one capture (DEVIATION 2: rr2_* rejects -U/-Ua records' `lanes: -`
# and repeated refusal rows, so these extract inline, the
# tests/gsa-install-v2.sh idiom).
record_scalar() {
    printf '%s\n' "$FIXTURE_OUTPUT" | sed -n '/^--- run record begin ---$/,/^--- run record end ---$/p' \
        | sed -n "s/^$1: //p" | head -n 1
}

record_section() {
    printf '%s\n' "$FIXTURE_OUTPUT" | sed -n '/^--- run record begin ---$/,/^--- run record end ---$/p' \
        | awk -v sec="$1" '
            $0 == "--- " sec " ---" { p = 1; next }
            /^--- / { p = 0 }
            p { print }'
}

# ─── A. the -U transaction carries exactly -U --noconfirm --ask 4 ───────────
dir_a="$fixture/case-a"
make_case_ws "$dir_a"
arch_a="$dir_a/packages/p1/p1-1.0.0-1-any.pkg.tar.zst"
stage_archive "$arch_a" p1 p1 1.0.0-1
: >"$dir_a/pacman.log"
: >"$dir_a/sudo.log"
: >"$fixture/seam.log"

# §E.5 rc 0: a clean plan is `install ok` and touches nothing else.
seam_run "$dir_a" --install-decide checked "$arch_a"
assert_decisions 'A: clean plan at the seam (§E.5 rc 0)' 0 <<'EOF'
p1 install ok
EOF
[[ ! -s "$fixture/seam.log" ]] ||
    fail "A: the decision seam reached pacman/sudo: $(cat "$fixture/seam.log")"

run_install "$dir_a" -U --state-dir "$dir_a/state" --config "$dir_a/pacman.conf" p1
[[ $FIXTURE_RC == 0 ]] ||
    fail "A: -U run failed (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
assert_argv 'A: the -U transaction must be exactly -U --noconfirm --ask 4 --config <conf> <archive> — the --ask 4 mask IS the stock-conflict removal contract' \
    "$dir_a/pacman.log" \
    -U --noconfirm --ask 4 --config "$dir_a/pacman.conf" "$arch_a"
[[ $(record_scalar outcome) == success && $(record_scalar rc) == 0 ]] ||
    fail "A: the run record must be outcome success rc 0: $FIXTURE_OUTPUT"
record_section outcome | grep -Eq '^p1 succeeded 0 [0-9]+ ok$' ||
    fail "A: the record must row 'p1 succeeded 0 <dur> ok' (§H.3): $FIXTURE_OUTPUT"
printf 'A: -U transaction flags pinned OK\n'

# ─── B. -Ua extra args ride after the flags, same command ───────────────────
dir_b="$fixture/case-b"
make_case_ws "$dir_b"
arch_b="$dir_b/packages/p1/p1-1.0.0-1-any.pkg.tar.zst"
stage_archive "$arch_b" p1 p1 1.0.0-1
: >"$dir_b/pacman.log"
: >"$dir_b/sudo.log"
run_install "$dir_b" -Ua --state-dir "$dir_b/state" --config "$dir_b/pacman.conf" -- --overwrite '*'
[[ $FIXTURE_RC == 0 ]] ||
    fail "B: -Ua --overwrite run failed (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
assert_argv 'B: -Ua -- --overwrite must follow -U --noconfirm --ask 4 --config <conf> in the SAME command, before the archives (§B.1)' \
    "$dir_b/pacman.log" \
    -U --noconfirm --ask 4 --config "$dir_b/pacman.conf" --overwrite '*' "$arch_b"
printf 'B: -Ua -- --overwrite forwarding pinned OK\n'

# ─── C. refusal rows never reach the pacman stub ────────────────────────────
# The --install-decide seam prints the plan verbatim without executing; the
# executor aborts on any refusal row BEFORE the transaction. Either way a
# refused plan must leave the pacman stub untouched — the --ask 4 auto-YES
# must never fire for a transaction that was refused.
dir_c="$fixture/case-c"
make_case_ws "$dir_c"
add_package "$dir_c" p2 'pkgver=1.0.0
pkgrel=1
arch=(any)
build() {
  CFLAGS+=" -fprofile-generate"
}'

# C1: checked mode with nothing to install → `refuse empty-list`, no
# execution, no pacman. (R-5: the tab plan_row codec has no v2 form — the row
# MEANING re-pins as a (pkgbase, decision, reason-key) triple through
# rr2_decisions, §E.2.)
: >"$dir_c/pacman.log"
: >"$dir_c/sudo.log"
: >"$fixture/seam.log"

# §E.5 rc 2: the seam's own zero-archive call is bad usage and prints no rows
# (DEVIATION 1).
seam_run "$dir_c" --install-decide checked
assert_decisions 'C1: a zero-archive seam call is §E.5 bad usage' 2 </dev/null

# Real archives everywhere (§E.3): a zero-byte "archive" refuses
# discover-failed — fail-closed, never a silent plan.
empty="$fixture/c1-empty-1.0.0-1-any.pkg.tar.zst"
: >"$empty"
seam_run "$dir_c" --install-decide checked "$empty"
assert_decisions 'C1: an empty file is not an archive (§E.3)' 1 <<'EOF'
- refuse discover-failed
EOF

# The `refuse empty-list` row at its reachable entry (DEVIATION 1): the -U
# plan over a workspace with nothing built — checked refuses, -Ua noops
# (§B.6/§E.3), each as §E.2 rows.
run_install "$dir_c" -U --dry-run --state-dir "$dir_c/state" --config "$dir_c/pacman.conf" p1
assert_rows 'C1 (checked, empty list)' <<'EOF'
- refuse empty-list
EOF
run_install "$dir_c" -Ua --dry-run --state-dir "$dir_c/state" --config "$dir_c/pacman.conf"
assert_rows 'C1 (-Ua, empty list is a noop)' <<'EOF'
- noop empty-list
EOF

# The executed refusal: rc 3 (§G.1), record-derived rows, and the plan never
# reaches the pacman or sudo stubs.
run_install "$dir_c" -U --state-dir "$dir_c/state" --config "$dir_c/pacman.conf" p1
[[ $FIXTURE_RC == 3 ]] ||
    fail "C1: an executed empty-list refusal is rc 3 (§G.1), got rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
[[ $(record_scalar outcome) == refused && $(record_scalar rc) == 3 ]] ||
    fail "C1: the record must be outcome refused rc 3: $FIXTURE_OUTPUT"
record_section plan | grep -qxF -- '- refused empty-list' ||
    fail "C1: the plan row must record the empty-list refusal (§H.2): $FIXTURE_OUTPUT"
record_section outcome | grep -qxF -- '- never-started - - install-refused empty-list' ||
    fail "C1: the outcome row must record install-refused empty-list (§H.3): $FIXTURE_OUTPUT"
[[ ! -s "$dir_c/pacman.log" ]] ||
    fail "C1: a refusal row reached the pacman stub: $(cat "$dir_c/pacman.log")"
[[ ! -s "$dir_c/sudo.log" ]] ||
    fail "C1: a refused plan escalated via sudo: $(cat "$dir_c/sudo.log")"
printf 'C1: empty-list refusal never reaches pacman OK\n'

# C2/C3: a PGO-instrumented payload → pgo refusal rows. C2 pins the seam's
# rows; C3 runs the real executors over the same archive and pins that the
# refusal aborts before any pacman invocation.
stage=$(mktemp -d "$fixture/stage.XXXXXX")
stage_pkginfo "$stage" p2 p2 1.0.0-1
mkdir -p "$stage/usr/bin"
printf 'code\0/home/someone/build/pgo-fixture/src/A.dir/b.cxx.gcda\0code\n' \
    >"$stage/usr/bin/p2"
arch="$dir_c/packages/p2/p2-1.0.0-1-any.pkg.tar.zst"
make_archive "$arch" "$stage"

: >"$dir_c/pacman.log"
: >"$dir_c/sudo.log"
: >"$fixture/seam.log"
seam_run "$dir_c" --install-decide force "$arch"
# R-5 §E.2 re-pin: the pgo refusal rows' MEANING keeps as
# (p2, refuse, pgo-hit) + (p2, refuse, pgo-instrumented) in plan order (the
# detail after pgo-hit — the member path — is not byte-pinned, §7).
assert_decisions 'C2: §E.2 pgo refusal rows' 1 <<'EOF'
p2 refuse pgo-hit
p2 refuse pgo-instrumented
EOF
[[ ! -s "$fixture/seam.log" ]] ||
    fail "C2: a decision-only run reached pacman/sudo: $(cat "$fixture/seam.log")"
printf 'C2: pgo refusal rows pinned OK\n'

# C3a: the -U executor over the same archive refuses rc 3 (§G.1) with
# record-derived rows (the prose pin's replacement, §H.3), and the refusal
# reaches neither pacman nor sudo.
: >"$dir_c/pacman.log"
: >"$dir_c/sudo.log"
run_install "$dir_c" -U --state-dir "$dir_c/state" --config "$dir_c/pacman.conf" "$arch"
[[ $FIXTURE_RC == 3 ]] ||
    fail "C3: -U over a PGO-instrumented payload must refuse (rc 3, §G.1): $FIXTURE_OUTPUT"
[[ $(record_scalar outcome) == refused && $(record_scalar rc) == 3 ]] ||
    fail "C3: the record must be outcome refused rc 3: $FIXTURE_OUTPUT"
# Per-subject row collapse (contract §H.2 amendment (a), 2026-10-14): ONE
# plan row and ONE outcome row per package, every refusal reason joined in
# row order, `order` duplicate-free — the multi-row per-finding granularity
# stays pinned at the seam above (C2), never in the run record.
[[ $(record_scalar order) == p2 ]] ||
    fail "C3: the order scalar must list p2 once per subject (contract §H.2 amendment (a), 2026-10-14): $FIXTURE_OUTPUT"
[[ $(record_section plan | grep -c '^p2 ') == 1 ]] ||
    fail "C3: the plan must carry one row for p2 (contract §H.2 amendment (a), 2026-10-14): $FIXTURE_OUTPUT"
record_section plan | grep -Eq '^p2 refused pgo-hit .*pgo-instrumented' ||
    fail "C3: the plan row must record the pgo-hit and pgo-instrumented refusals joined (§H.2, amendment (a) 2026-10-14): $FIXTURE_OUTPUT"
[[ $(record_section outcome | grep -c '^p2 ') == 1 ]] ||
    fail "C3: the outcome must carry one row for p2 (contract §H.2 amendment (a), 2026-10-14): $FIXTURE_OUTPUT"
record_section outcome | grep -Eq '^p2 never-started - - install-refused pgo-hit .*install-refused pgo-instrumented' ||
    fail "C3: the outcome row must record install-refused pgo-hit and install-refused pgo-instrumented joined (§H.3, amendment (a) 2026-10-14): $FIXTURE_OUTPUT"
[[ ! -s "$dir_c/pacman.log" ]] ||
    fail "C3: install execution ran pacman despite a refusal row: $(cat "$dir_c/pacman.log")"
[[ ! -s "$dir_c/sudo.log" ]] ||
    fail "C3: a refused transaction escalated via sudo: $(cat "$dir_c/sudo.log")"

# C3b: the -Ua executor (today's -ia spelling) refuses the same way — zero
# transactions and never an escalated `sudo … pacman` (DEVIATION 4: the
# §K.3 `sudo -n true` preflight probe may run).
: >"$dir_c/pacman.log"
: >"$dir_c/sudo.log"
run_install "$dir_c" -Ua --state-dir "$dir_c/state" --config "$dir_c/pacman.conf"
[[ $FIXTURE_RC == 3 ]] ||
    fail "C3: -Ua over a PGO-instrumented payload must refuse (rc 3, §G.1): $FIXTURE_OUTPUT"
[[ $(record_scalar outcome) == refused && $(record_scalar rc) == 3 ]] ||
    fail "C3: the -Ua record must be outcome refused rc 3: $FIXTURE_OUTPUT"
# Same per-subject grammar as C3a (contract §H.2 amendment (a), 2026-10-14).
[[ $(record_scalar order) == p2 ]] ||
    fail "C3: the -Ua order scalar must list p2 once per subject (contract §H.2 amendment (a), 2026-10-14): $FIXTURE_OUTPUT"
[[ $(record_section plan | grep -c '^p2 ') == 1 ]] ||
    fail "C3: the -Ua plan must carry one row for p2 (contract §H.2 amendment (a), 2026-10-14): $FIXTURE_OUTPUT"
record_section plan | grep -Eq '^p2 refused pgo-hit .*pgo-instrumented' ||
    fail "C3: the -Ua plan row must record the pgo-hit and pgo-instrumented refusals joined (§H.2, amendment (a) 2026-10-14): $FIXTURE_OUTPUT"
[[ $(record_section outcome | grep -c '^p2 ') == 1 ]] ||
    fail "C3: the -Ua outcome must carry one row for p2 (contract §H.2 amendment (a), 2026-10-14): $FIXTURE_OUTPUT"
record_section outcome | grep -Eq '^p2 never-started - - install-refused pgo-hit .*install-refused pgo-instrumented' ||
    fail "C3: the -Ua outcome row must record install-refused pgo-hit and install-refused pgo-instrumented joined (§H.3, amendment (a) 2026-10-14): $FIXTURE_OUTPUT"
[[ ! -s "$dir_c/pacman.log" ]] ||
    fail "C3: install execution ran pacman despite a refusal row: $(cat "$dir_c/pacman.log")"
if grep -q pacman "$dir_c/sudo.log"; then
    fail "C3: a refused -Ua transaction escalated via sudo: $(cat "$dir_c/sudo.log")"
fi
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
# The executor half of the row-codec contract: install execution must hand the
# WHOLE archive path to pacman as one argument. The old space-joined rows
# truncated at the first space and pacman got a nonexistent path, aborting
# the transaction. The workspace root carries the space so the DISCOVERED
# archive path does; the stub logs one argv per line, so a split path shows
# up as a truncated argv line and a lost remainder.
(
    dir_e="$fixture/case-e"
    ws="$dir_e/the ws"
    make_case_ws "$ws"
    arch_e="$ws/packages/p1/p1-1.0.0-1-any.pkg.tar.zst"
    stage_archive "$arch_e" p1 p1 1.0.0-1
    : >"$ws/pacman.log"
    : >"$ws/sudo.log"
    run_install "$ws" -Ua --state-dir "$ws/state" --config "$ws/pacman.conf"
    ((FIXTURE_RC == 0)) ||
        fail "E: -Ua over a spaced path must succeed, got rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
    txn=$(txn_argv "$ws/pacman.log")
    hits=$(grep -cxF "$arch_e" <<<"$txn" || true)
    [[ $hits == 1 ]] ||
        fail "E: pacman never received the full spaced path as one argv: $(cat "$ws/pacman.log")"
    if grep -qxF "${arch_e%% *}" <<<"$txn"; then
        fail "E: the archive path was truncated at the first space: $(cat "$ws/pacman.log")"
    fi
    printf 'E: spaced archive path reaches pacman intact OK\n'
)

printf 'install conflict-ask fixture: PASS\n'
