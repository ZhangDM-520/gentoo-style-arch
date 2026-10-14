#!/usr/bin/env bash
set -euo pipefail

# Regression fixture for install archive discovery and its refusal semantics
# (docs/gsa-fixture-migration.md inventory row `tests/install-archive-guard.sh`,
# phase 3 — install pipeline discovery + skip semantics + decision sets via
# `--install-decide`).
#
# The invariant this fixture enforces is behavioural, not textual: a run that
# reports success under an install run must have actually installed something.
# The missing-archive half pins the other side — when the archive genuinely
# cannot be found the run must FAIL, because silence is what hid the bug for
# so long.
#
# Flip notes (docs/gsa-fixture-migration.md row `tests/install-archive-guard.sh`):
# argv map: fish `--no-deps --no-sync -i/-ia/-fi/-s …` -> `gsa -S --leaf`,
# `gsa -U`, `gsa -Uf`, `gsa -Ua` (§B.4–B.8); decision sets drive the hidden
# `gsa --install-decide <checked|force> <archive…>` seam (§D.1) and parse
# through the §E.2 row grammar (`rr2_decisions`, plus exact full rows where
# the reason DETAIL is the pin). `-S` runs assert through strict `format: 2`
# records (`rr2_*`). `-U`/`-Ua` records render `lanes: -` and `-` subjects
# (known §H conformance debt — the tests/gsa-install-v2.sh preamble) and are
# row-extracted INLINE here, exactly like tests/gsa-install-v2.sh. R-5
# re-pin (§6): the tab `plan_row` codec and its exact-plan equalities retire
# with the framing; the row MEANINGS re-pin as §E.2 rows and §H rows. Prose
# pins retire (§6/§L.3): every former byte-pinned message now asserts on a
# decision row, a run-record row/field, or a stub-log artefact. R-1/R-2
# classes (§6: fish source-shape greps, the format:1 single-token reason
# rule) never applied to this fixture and hold no sites here.
#
# DEVIATION 1 (the `--skip` run sites stay fish-driven — inventory row
# "REWRITE argv … runs `gsa -S`, `-Uf`, `-Ua`, `--skip`, `--leaf`"): the
# engine defers `--skip` (parse-and-refuse rc 2, "gsa: deferred to a later
# phase: --skip"), so cases G/H cannot exercise real skip-if-fresh behaviour
# through it. They keep driving the fish builder these workspaces carry (the
# tests/abi-postinstall-probe.sh mixed pattern) with their build-skip and
# skip/force-install assertions intact.
# DEVIATION 2 (discovery mechanism — inventory KEEP cell "discovery
# semantics"): the engine takes each archive's version from its OWN
# `.PKGINFO` and selects the newest archive per output name
# (crates/gsa-install/src/lib.rs `discover_recipe`); it never evaluates
# PKGBUILD assignment text, so the fish-era name-matching bug class (trailing
# comment / shell expression / epoch filename join in `list_split_pkgs`) has
# no engine trigger. The kept invariant re-pins through the transaction log:
# the archive that transacts is the one the build produced for the EVALUATED
# pkgver (comment stripped, expression expanded, pkgver() resolved, epoch
# joined), and a stale pre-build archive never rides along. The epoch half of
# "evaluated pkgver" also pins at the seam's canonical version
# (`2:1.0.0-1` — makepkg's get_full_version join, the 2026-10-06 finding).
# DEVIATION 3 (old case K — inventory REWRITE prose ":390"): "a PKGBUILD
# evaluation diagnostic must stay on stderr, never become an archive
# argument" is structurally absent (there is no PKGBUILD evaluation in the
# engine's discovery). The fail-closed counterpart pins instead: damaged
# archive metadata refuses `discover-failed` (§E.3) or skips
# `unreadable-pkginfo` when a committed `.SRCINFO` establishes the names.
# DEVIATION 4 (old case S3 — inventory KEEP cell "split-set completeness",
# target row `refuse partial-set`): fish `-ia` merely EXCLUDED a partial
# split set and no-op'd; the engine refuses it fail-closed
# (`refuse partial-set <dir> <missing>`, rc 3) under checked AND force —
# the §E.3 `refuse` meaning. The force-empty `noop empty-list` keeps where
# §E.3 defines it (zero eligible archives).
#
# Nothing here touches the real repository: workspaces are synthetic under
# $TMPDIR, engine state under per-case --state-dir roots, the pacman local
# database is fabricated (`<db>/local/<name>-<ver>/{desc,files}`; the entry
# directory's mtime IS the install date — crates/gsa-install/src/localdb.rs)
# and read through a `pacman-conf DBPath` stub, and pacman/sudo/makepkg stay
# stubs.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-install-guard.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    printf 'install archive guard fixture: %s\n' "$1" >&2
    if [ -n "${2:-}" ] && [ -f "$2" ]; then
        sed 's/^/    /' "$2" >&2
    fi
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

# ─── Engine-side synthesis (inline per §D.2 — oracles live in the fixture
# that gives them meaning; expectations derive from what this fixture
# stages, never from pinned counts) ────────────────────────────────────────

# fullver EPOCH PKGVER PKGREL — the engine's canonical version
# (crates/gsa-recipe/src/pkginfo.rs canonical_version: `epoch:pkgver-pkgrel`,
# epoch 0 when undeclared). Expected-row versions are always computed here.
fullver() {
    local epoch=${1:-0}
    [ -n "$epoch" ] || epoch=0
    printf '%s:%s-%s\n' "$epoch" "$2" "$3"
}

# make_pkg_archive OUT PKGBASE PKGNAME PKGVER PKGREL [EPOCH] — one REAL
# archive (a staged .PKGINFO tar): the engine's discovery reads each
# archive's own metadata, so a trivial empty file is not a valid input.
make_pkg_archive() {
    local out=$1 base=$2 name=$3 ver=$4 rel=$5 epoch=${6:-}
    local stage="$fixture/stage-$base-$name-$RANDOM"
    mkdir -p "$stage" "$(dirname "$out")"
    {
        printf 'pkgbase = %s\npkgname = %s\npkgver = %s\npkgrel = %s\n' \
            "$base" "$name" "$ver" "$rel"
        [ -n "$epoch" ] && printf 'epoch = %s\n' "$epoch"
        printf 'arch = any\n'
    } >"$stage/.PKGINFO"
    tar --zstd -cf "$out" -C "$stage" .PKGINFO
    rm -rf -- "$stage"
}

# db_install DBROOT NAME FULL-VERSION — one fabricated pacman local-DB
# entry. The caller touches the printed entry dir to place the install date.
db_install() {
    local dir="$1/local/$2-$3"
    mkdir -p "$dir"
    printf '%%NAME%%\n%s\n\n%%VERSION%%\n%s\n' "$2" "$3" >"$dir/desc"
    printf '%%FILES%%\n' >"$dir/files"
    printf '%s\n' "$dir"
}

# write_engine_stubs DIR DBROOT — the engine's four stubs: a pacman argv log,
# a sudo passthrough with an argv log, `pacman-conf DBPath` -> the fabricated
# DB root (never the host's), and a no-op makepkg (build cases write their
# own scenario stub).
write_engine_stubs() {
    local ws=$1 db=$2
    mkdir -p "$ws/bin" "$db"
    cat >"$ws/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'pacman %s\n' "$*" >>"${GSA_FAKE_PACMAN_LOG:?}"
exit 0
EOF
    cat >"$ws/bin/sudo" <<'EOF'
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
    cat >"$ws/bin/pacman-conf" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = DBPath ] && printf '%s\n' "$db"
exit 0
EOF
    printf '#!/usr/bin/env bash\nexit 0\n' >"$ws/bin/makepkg"
    chmod +x "$ws/bin/pacman" "$ws/bin/sudo" "$ws/bin/pacman-conf" "$ws/bin/makepkg"
}

# write_eval_makepkg DIR — the scenario makepkg with makepkg's own version
# evaluation: source the PKGBUILD (assignment VALUES and shell expressions),
# run pkgver() when defined, join epoch into the filename version
# (get_full_version), rewrite the PKGBUILD like a VCS build does, and stamp
# the archive's .PKGINFO with that truth. Knob-free: the recipe under test
# declares the shape.
write_eval_makepkg() {
    cat >"$1/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
id=$(basename "$PWD")
read -r ver rel epoch < <(bash -c '
    source ./PKGBUILD >/dev/null 2>&1 || exit 1
    declare -F pkgver >/dev/null && pkgver=$(pkgver)
    printf "%s %s %s\n" "$pkgver" "${pkgrel:-1}" "${epoch:-}"')
[ -n "$ver" ] || exit 1
sed -i "s/^pkgver=.*/pkgver=$ver/" ./PKGBUILD
fname=$ver-$rel
[ -n "$epoch" ] && fname=$epoch:$fname
stage="$PWD/.stage-$id"
mkdir -p "$stage"
{
    printf 'pkgbase = %s\npkgname = %s\npkgver = %s\npkgrel = %s\n' "$id" "$id" "$ver" "$rel"
    [ -n "$epoch" ] && printf 'epoch = %s\n' "$epoch"
    printf 'arch = any\n'
} >"$stage/.PKGINFO"
tar --zstd -cf "$PWD/$id-$fname-any.pkg.tar.zst" -C "$stage" .PKGINFO
rm -rf "$stage"
exit 0
EOF
    chmod +x "$1/bin/makepkg"
}

# run_inst WS ARGS... — one engine run over an engine workspace (per-case
# state root and stub PATH; the run's argv is the §B grammar).
run_inst() {
    local ws=$1
    shift
    PATH="$ws/bin:$PATH" \
        GSA_FAKE_PACMAN_LOG="$ws/pacman.log" \
        GSA_FAKE_SUDO_LOG="$ws/sudo.log" \
        GSA_STATE_DIR="$ws/state" \
        GSA_CPU_THREADS=8 \
        GSA_MEMORY_GIB=16 \
        run_engine "$ws" "$@"
    return 0
}

# rows_only — the §E.2 decision rows of a capture as printed by the seam or a
# `--dry-run` plan (rows precede the prose/record span; the record's own
# sections share the framing and are excluded with it). Engine diagnostics
# dropped.
rows_only() {
    awk '/^--- run record begin ---/ || /^Build run: / { exit } !/^gsa: / && NF { print }'
}

# record_scalar KEY / record_section plan|outcome — the machine block of a
# capture, extracted INLINE: `-U`/`-Ua` records render `lanes: -` and `-`
# subjects, so rr2_* rejects them (known §H debt; tests/gsa-install-v2.sh).
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

# assert_decisions LABEL RC — the §E.2 re-pin: the capture's normalized
# (pkgbase, decision, reason-key) rows exactly as given on stdin, in plan
# order, plus the seam's rc contract (§E.5: 0 = no refuse row / 1 = >=1
# refuse row / 2 = bad usage and no rows).
assert_decisions() {
    local label=$1 rc=$2 want got
    want=$(cat)
    got=$(rows_only <<<"$FIXTURE_OUTPUT" | rr2_decisions) || {
        printf '%s: unparsable §E.2 decision rows:\n%s\n' "$label" "$FIXTURE_OUTPUT" >&2
        exit 1
    }
    if [ "$got" != "$want" ]; then
        printf '%s: wrong §E.2 decision rows (pkgbase decision reason-key, plan order).\nwant:\n%s\ngot:\n%s\noutput: %s\n' \
            "$label" "$want" "$got" "$FIXTURE_OUTPUT" >&2
        exit 1
    fi
    if [ "$FIXTURE_RC" != "$rc" ]; then
        printf '%s: seam rc=%s want=%s (§E.5):\n%s\n' "$label" "$FIXTURE_RC" "$rc" "$FIXTURE_OUTPUT" >&2
        exit 1
    fi
    if [ "$rc" = 0 ] && printf '%s\n' "$got" | grep -q ' refuse '; then
        printf '%s: an rc 0 plan contains a refuse row (§E.5): %s\n' "$label" "$got" >&2
        exit 1
    fi
    if [ "$rc" = 1 ] && ! printf '%s\n' "$got" | grep -q ' refuse '; then
        printf '%s: an rc 1 plan has no refuse row (§E.5): %s\n' "$label" "$got" >&2
        exit 1
    fi
    if [ "$rc" = 2 ] && [ -n "$got" ]; then
        printf '%s: an rc 2 bad-usage call printed decision rows (§E.5): %s\n' "$label" "$got" >&2
        exit 1
    fi
}

# assert_rows LABEL — the FULL §E.2 rows exactly as given on stdin (the
# reason DETAIL is the pin here), for a plan entry that is not the decision
# seam (its rc is the run's class, §G.1, not the §E.5 mapping).
assert_rows() {
    local label=$1 want got
    want=$(cat)
    got=$(rows_only <<<"$FIXTURE_OUTPUT") || {
        printf '%s: unparsable §E.2 decision rows:\n%s\n' "$label" "$FIXTURE_OUTPUT" >&2
        exit 1
    }
    if [ "$got" != "$want" ]; then
        printf '%s: wrong §E.2 decision rows (full rows, plan order).\nwant:\n%s\ngot:\n%s\noutput: %s\n' \
            "$label" "$want" "$got" "$FIXTURE_OUTPUT" >&2
        exit 1
    fi
}

# txn_count / txn_argv / pacman_mut_count — the pacman stub log's facts.
# A build run also logs the toolchain gate's read-only `pacman -Q rust-git`
# probe (crates/gsa-recipe/src/toolchain.rs), and queries are not transactions
# (the query/transaction split tests/pacman-mutex-shim.sh pins), so a
# transaction is a `-U` line. pacman_mut_count counts everything that is NOT
# a read-only `-Q…` probe: the zero-transaction sites use it, so any mutating
# pacman call — whatever the verb — still fails them (§E.1 keeps the *seam*
# fully pacman-free; that pin lives in the seam section below).
txn_count() { grep -c '^pacman -U ' "$1" 2>/dev/null || true; }
pacman_mut_count() { grep -cv '^pacman -Q' "$1" 2>/dev/null || true; }
txn_argv() { sed -n 's/^pacman //p' "$1" 2>/dev/null || true; }

# ─── The hidden seam's fabricated state (§D.1: decision rows on stdout, no
# pacman/sudo/flock/makepkg — the only subprocess is `pacman-conf DBPath`) ──
mkdir -p "$fixture/gsa-db/local" "$fixture/gsa-bin"
cat >"$fixture/gsa-bin/pacman-conf" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = DBPath ] && printf '%s\n' "$fixture/gsa-db"
exit 0
EOF
chmod +x "$fixture/gsa-bin/pacman-conf"
for stub in pacman sudo; do
    cat >"$fixture/gsa-bin/$stub" <<EOF
#!/usr/bin/env bash
printf 'UNEXPECTED $stub in a decision-only run: %s\n' "\$*" >&2
exit 99
EOF
    chmod +x "$fixture/gsa-bin/$stub"
done

gsa_db_reset() {
    rm -rf "$fixture/gsa-db"
    mkdir -p "$fixture/gsa-db/local"
}

gsa_decide() { # MODE [ARCHIVE...] — the §E.2 seam over the fabricated state
    local mode=$1
    shift
    local PATH="$fixture/gsa-bin:$PATH"
    run_engine "$seam_ws" --install-decide "$mode" "$@"
}

# The seam runs with a valid workspace as cwd (workspace discovery is §8 gap
# G11; run_engine runs gsa with the workspace as cwd until the contract says
# otherwise).
seam_ws="$fixture/seam-ws"
make_workspace "$seam_ws" 1 2 low

# ─── Section 1: discovery — the archive that transacts is the build's own,
# carrying the EVALUATED pkgver (inventory KEEP cell "discovery semantics";
# DEVIATION 2 names the mechanism change). Each case stages a DECOY stale
# archive whose .PKGINFO names another version: installing it (or both) is
# the regression. ─────────────────────────────────────────────────────────
discovery_case() { # $1 = label, $2 = extra PKGBUILD lines — the expected
    # version is derived exactly as makepkg derives it (the stub is the
    # oracle), so no case pins a filename the fixture did not compute.
    local label=$1 extra=$2
    local ws="$fixture/disc-$label"
    make_workspace "$ws" 1 2 low
    write_engine_stubs "$ws" "$ws/db"
    add_package "$ws" p1 "$extra"
    write_eval_makepkg "$ws"
    : >"$ws/pacman.log"
    # decoy: an older archive for a DIFFERENT version must never ride along
    make_pkg_archive "$ws/packages/p1/p1-0.9.0-1-any.pkg.tar.zst" p1 p1 0.9.0 1
    touch -d '2001-01-01' "$ws/packages/p1/p1-0.9.0-1-any.pkg.tar.zst"
    run_inst "$ws" -S --leaf --config "$ws/pacman.conf" p1
    if [ "$FIXTURE_RC" != 0 ]; then
        printf '%s: engine run failed on a valid recipe:\n%s\n' "$label" "$FIXTURE_OUTPUT" >&2
        exit 1
    fi
    rr2_body <<<"$FIXTURE_OUTPUT" >/dev/null ||
        { printf '%s: no complete format: 2 run record:\n%s\n' "$label" "$FIXTURE_OUTPUT" >&2; exit 1; }
    [ "$(rr2_scalar rc <<<"$FIXTURE_OUTPUT")" = 0 ] ||
        fail "$label: record rc is not 0: $FIXTURE_OUTPUT"
    [ "$(rr2_scalar outcome <<<"$FIXTURE_OUTPUT")" = success ] ||
        fail "$label: run must record outcome success: $FIXTURE_OUTPUT"
    [ "$(rr2_plan p1 plan <<<"$FIXTURE_OUTPUT")" = build-install ] ||
        fail "$label: p1 must be planned build-install: $FIXTURE_OUTPUT"
    [ "$(rr2_outcome p1 status <<<"$FIXTURE_OUTPUT")" = succeeded ] ||
        fail "$label: p1 did not succeed: $FIXTURE_OUTPUT"
    # the success must be REAL: a transaction ran and it named the freshly
    # built archive — and never the stale decoy (A3's staleness half)
    [ "$(txn_count "$ws/pacman.log")" = 1 ] ||
        fail "$label: want exactly one pacman -U, got $(txn_count "$ws/pacman.log"):" "$ws/pacman.log"
    fresh=$(find "$ws/packages/p1" -name '*.pkg.tar.zst' ! -name 'p1-0.9.0-1-any.pkg.tar.zst' -print -quit)
    [ -n "$fresh" ] || fail "$label: the build produced no archive beside the decoy:" "$ws/packages/p1"
    txn_argv "$ws/pacman.log" | grep -F -- "$fresh" >/dev/null ||
        fail "$label: pacman -U did not receive the freshly built archive $fresh:" "$ws/pacman.log"
    if txn_argv "$ws/pacman.log" | grep -F -- 'p1-0.9.0-1-any.pkg.tar.zst' >/dev/null; then
        fail "$label: a stale pre-build archive rode along in the transaction:" "$ws/pacman.log"
    fi
}

# A: a trailing comment on pkgver= is metadata, not text to mis-parse — the
# evaluated value (1.0.0) is what the built archive carries.
discovery_case comment $'pkgver=1.0.0 # bump me\npkgrel=1\narch=(any)'

# A2: a legal shell expression is metadata too — expanded to 5.3.15.2.
discovery_case expr $'_basever=5.3.15\n_patchlevel=2\npkgver=${_basever}.${_patchlevel}\npkgrel=1\narch=(any)'

# A3: makepkg resolves pkgver() during the build and updates the PKGBUILD;
# the archive for the POST-build version transacts, the pre-build archive
# (0.9.0 decoy above) never does.
discovery_case vcs $'pkgver=1.0.0\npkgrel=1\narch=(any)\npkgver() { echo 2.0.r7.gabc123; }'

# A4: an epoch-bearing recipe archives as NAME-epoch:pkgver-pkgrel-arch
# (makepkg's get_full_version) and its canonical version JOINS the epoch
# (the 2026-10-06 full-build finding: ninja-git built fine and the install
# then refused because the expected stem lacked the `2:`). The transaction
# must receive the epoch-joined archive; the seam re-pins the join as the
# canonical version in the skip row.
ws="$fixture/disc-epoch"
make_workspace "$ws" 1 2 low
write_engine_stubs "$ws" "$ws/db"
add_package "$ws" p1 $'epoch=2\npkgver=1.0.0\npkgrel=1\narch=(any)'
write_eval_makepkg "$ws"
: >"$ws/pacman.log"
make_pkg_archive "$ws/packages/p1/p1-0.9.0-1-any.pkg.tar.zst" p1 p1 0.9.0 1
touch -d '2001-01-01' "$ws/packages/p1/p1-0.9.0-1-any.pkg.tar.zst"
run_inst "$ws" -S --leaf --config "$ws/pacman.conf" p1
[ "$FIXTURE_RC" = 0 ] || fail "A4: engine run failed on an epoch-bearing recipe: $FIXTURE_OUTPUT"
rr2_body <<<"$FIXTURE_OUTPUT" >/dev/null || fail "A4: no complete format: 2 run record: $FIXTURE_OUTPUT"
[ "$(rr2_outcome p1 status <<<"$FIXTURE_OUTPUT")" = succeeded ] ||
    fail "A4: p1 did not succeed: $FIXTURE_OUTPUT"
epoch_archive="$ws/packages/p1/p1-2:1.0.0-1-any.pkg.tar.zst"
[ -f "$epoch_archive" ] ||
    fail "A4: the build did not produce the epoch-joined archive name:" "$ws/packages/p1"
[ "$(txn_count "$ws/pacman.log")" = 1 ] || fail "A4: want one transaction:" "$ws/pacman.log"
txn_argv "$ws/pacman.log" | grep -F -- "$epoch_archive" >/dev/null ||
    fail "A4: pacman -U did not receive the epoch-prefixed archive:" "$ws/pacman.log"
if txn_argv "$ws/pacman.log" | grep -F -- 'p1-0.9.0-1-any.pkg.tar.zst' >/dev/null; then
    fail "A4: a stale archive rode along in the epoch transaction:" "$ws/pacman.log"
fi

# A4 seam half: the evaluated (epoch-joined) version is the one the
# same-version check compares. DB `2:1.0.0-1` fresh -> skip; a DB entry
# WITHOUT the join (`1.0.0-1`) must not match -> doubt installs.
gsa_db_reset
epoch_arch="$fixture/gsa-archives/p1-epoch.pkg.tar.zst"
make_pkg_archive "$epoch_arch" p1 p1 1.0.0 1 2
touch -d '+1 day' "$(db_install "$fixture/gsa-db" p1 "$(fullver 2 1.0.0 1)")"
gsa_decide checked "$epoch_arch"
[ "$FIXTURE_RC" = 0 ] || fail "A4 seam: an rc 0 plan was expected: $FIXTURE_OUTPUT"
assert_rows 'A4 seam (epoch joined in the canonical version)' <<EOF
p1 skip already-current $(fullver 2 1.0.0 1)
EOF
gsa_db_reset
touch -d '+1 day' "$(db_install "$fixture/gsa-db" p1 "$(fullver '' 1.0.0 1)")"
gsa_decide checked "$epoch_arch"
assert_decisions 'A4 seam (no epoch join -> doubt installs)' 0 <<'EOF'
p1 install ok
EOF

# ─── Section 2: no archive at all must FAIL, never report success ─────────
# (inventory KEEP cell "missing-archive failure": a run that reports success
# must have actually installed something).
ws="$fixture/missing"
make_workspace "$ws" 1 2 low
write_engine_stubs "$ws" "$ws/db"
add_package "$ws" p1 $'pkgver=1.0.0\npkgrel=1\narch=(any)'
: >"$ws/pacman.log"
run_inst "$ws" -S --leaf --config "$ws/pacman.conf" p1
[ "$FIXTURE_RC" != 0 ] || fail "B: an install run succeeded with no package archive: $FIXTURE_OUTPUT"
rr2_body <<<"$FIXTURE_OUTPUT" >/dev/null || fail "B: no complete format: 2 run record: $FIXTURE_OUTPUT"
[ "$(rr2_scalar outcome <<<"$FIXTURE_OUTPUT")" = refused ] ||
    fail "B: the run must record outcome refused, never success: $FIXTURE_OUTPUT"
[ "$(rr2_scalar rc <<<"$FIXTURE_OUTPUT")" = "$FIXTURE_RC" ] ||
    fail "B: the record's rc scalar disagrees with the process exit code: $FIXTURE_OUTPUT"
rr2_outcome p1 reason <<<"$FIXTURE_OUTPUT" | grep -q '^install-refused empty-list' ||
    fail "B: the failing row must name the empty install set: $FIXTURE_OUTPUT"
[ "$(pacman_mut_count "$ws/pacman.log")" = 0 ] ||
    fail "B: pacman ran with nothing to install:" "$ws/pacman.log"

# ─── Section 3: the same-version sanity check and its force bypass ────────
# 2026-09-25: the resume idiom re-ran pacman -U for every already-built
# package even when its exact version was already installed. The engine
# skips an install only on POSITIVE evidence: exact canonical version match
# AND an install date (local-DB entry dir mtime) not older than the archive
# (nanosecond precision; a same-version rebuild still installs). Every
# doubt — no entry, no date, a version difference — installs. Force mode
# (-Uf / -Sf / -Ua) bypasses the check entirely. Decision sets pin at the
# seam (§D.1); execution pins at run level through `gsa -U`/`gsa -Uf`.

# I1: exact version installed, install fresher than the archive -> the one
# positive-evidence skip.
gsa_db_reset
touch -d '+1 day' "$(db_install "$fixture/gsa-db" p1 "$(fullver '' 1.0.0 1)")"
i1_arch="$fixture/gsa-archives/p1-i1.pkg.tar.zst"
make_pkg_archive "$i1_arch" p1 p1 1.0.0 1
gsa_decide checked "$i1_arch"
assert_decisions 'I1 (checked, fresh install)' 0 <<'EOF'
p1 skip already-current
EOF

# I2: version mismatch -> install (doubt installs).
gsa_db_reset
touch -d '+1 day' "$(db_install "$fixture/gsa-db" p1 "$(fullver '' 0.9.0 1)")"
gsa_decide checked "$i1_arch"
assert_decisions 'I2 (checked, version mismatch)' 0 <<'EOF'
p1 install ok
EOF

# I3: same version but the install PREDATES the archive — a rebuild that
# never reached the system. The freshness guard must install it.
gsa_db_reset
touch -d '-1 day' "$(db_install "$fixture/gsa-db" p1 "$(fullver '' 1.0.0 1)")"
gsa_decide checked "$i1_arch"
assert_decisions 'I3 (checked, stale install date)' 0 <<'EOF'
p1 install ok
EOF

# I4: nothing installed for the name -> install.
gsa_db_reset
gsa_decide checked "$i1_arch"
assert_decisions 'I4 (checked, no installed entry)' 0 <<'EOF'
p1 install ok
EOF

# I5: force mode over a perfectly fresh install -> install anyway, and the
# fabricated state is never consulted: force bypasses the same-version check
# entirely (-Ua/-Uf/-Sf share this path; no second implementation).
gsa_db_reset
touch -d '+1 day' "$(db_install "$fixture/gsa-db" p1 "$(fullver '' 1.0.0 1)")"
gsa_decide force "$i1_arch"
assert_decisions 'I5 (force bypasses the skip check)' 0 <<'EOF'
p1 install ok
EOF

# C'/F' at run level: the same pair through `gsa -U` (checked) and `gsa -Uf`
# (force). The skip is REPORTED as the record's plan/outcome rows (the old
# 'already installed' message pin retires with the prose, §L.3) and
# transacts nothing; force transacts exactly once.
ws="$fixture/run-skip"
make_workspace "$ws" 1 2 low
write_engine_stubs "$ws" "$ws/db"
add_package "$ws" p1 $'pkgver=1.0.0\npkgrel=1\narch=(any)'
arch_run="$ws/packages/p1/p1-1.0.0-1-any.pkg.tar.zst"
make_pkg_archive "$arch_run" p1 p1 1.0.0 1
touch -d '+1 day' "$(db_install "$ws/db" p1 "$(fullver '' 1.0.0 1)")"
: >"$ws/pacman.log"
run_inst "$ws" -U --config "$ws/pacman.conf" p1
[ "$FIXTURE_RC" = 0 ] || fail "C': a skip-only -U run must be rc 0 (§G.1), got $FIXTURE_RC: $FIXTURE_OUTPUT"
[ "$(record_scalar outcome)" = success ] || fail "C': skip must be reported as success: $FIXTURE_OUTPUT"
record_section plan | grep -Fx "p1 skip already-current $(fullver '' 1.0.0 1)" >/dev/null ||
    fail "C': the record must plan the same-version skip with its version: $FIXTURE_OUTPUT"
record_section outcome | grep -F "already-current $(fullver '' 1.0.0 1)" >/dev/null ||
    fail "C': the outcome row must keep the skip reason: $FIXTURE_OUTPUT"
[ "$(pacman_mut_count "$ws/pacman.log")" = 0 ] ||
    fail "C': a skipped package must not transact:" "$ws/pacman.log"
: >"$ws/pacman.log"
run_inst "$ws" -Uf --state-dir "$ws/state-f" --config "$ws/pacman.conf" p1
[ "$FIXTURE_RC" = 0 ] || fail "F': a forced -U run must be rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
record_section plan | grep -Fx 'p1 install ok' >/dev/null ||
    fail "F': the forced record must plan the install (§E.3): $FIXTURE_OUTPUT"
[ "$(txn_count "$ws/pacman.log")" = 1 ] ||
    fail "F': force must run exactly one pacman -U, got $(txn_count "$ws/pacman.log"):" "$ws/pacman.log"
txn_argv "$ws/pacman.log" | grep -F -- "$arch_run" >/dev/null ||
    fail "F': the forced transaction must name the archive:" "$ws/pacman.log"

# ─── Section 4 (DEVIATION 1): the --skip build-skip stays fish-driven ─────
# The engine defers `--skip` (parse-and-refuse rc 2), so the resume idiom's
# two halves — the BUILD is skipped (a skipped build never reaches makepkg)
# and the already-installed package is not reinstalled (or IS reinstalled
# under force) — keep driving the fish builder these workspaces carry.
# These sites keep their fish-era assertions on purpose.

make_case_workspace() { # $1 = sandbox dir — the FISH-era workspace for G/H
    local dir=$1
    make_workspace "$dir" 1 2 low
    stub_sleep "$dir"
    make_install_conf "$dir/pacman.conf"
    add_package "$dir" p1 $'pkgver=1.0.0\npkgrel=1\narch=(any)'
    cat >"$dir/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
: >"$PWD/p1-1.0.0-1-any.pkg.tar.zst"
# Invocation counter: the -s cases must observe that a SKIPPED build never
# reaches makepkg — the lane's "already built" line is silent in quiet mode.
if [[ -n ${GSA_FAKE_MAKEPKG_COUNT:-} ]]; then
    printf 'run\n' >>"$GSA_FAKE_MAKEPKG_COUNT"
fi
printf 'fake makepkg %s\n' "$PWD"
exit 0
EOF
    chmod +x "$dir/bin/makepkg"
    stub_sudo "$dir"
    cat >"$dir/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'pacman %s\n' "$*" >>"${GSA_FAKE_PACMAN_LOG:?}"
case ${1:-} in
-Qp)
    [[ -n ${GSA_FAKE_QP:-} ]] || exit 1
    printf '%s\n' "$GSA_FAKE_QP"
    ;;
-Qi)
    [[ -n ${GSA_FAKE_QI:-} ]] || exit 1
    printf '%s\n' "$GSA_FAKE_QI"
    ;;
esac
exit "${GSA_FAKE_PACMAN_RC:-0}"
EOF
    chmod +x "$dir/bin/pacman"
}

run_case() { # $1 = dir, $2 = extra env NAME=VALUE ...
    local dir=$1
    shift
    run_builder env "$@" \
        PATH="$dir/bin:$PATH" \
        GSA_STATE_DIR="$dir/state" \
        _IGNOREPKG_CONF="$dir/pacman.conf" \
        GSA_FAKE_PACMAN_LOG="$dir/pacman.log" \
        GSA_FAKE_MAKEPKG_COUNT="$dir/makepkg.count" \
        GSA_CPU_THREADS=8 \
        GSA_MEMORY_GIB=16 \
        fish "$dir/build-all.fish" \
        --allow-broken-rustc --no-deps --no-sync "${builder_args[@]}"
    return "$FIXTURE_RC"
}

fresh_qi() { # Install Date one day AFTER the archive about to be built
    printf 'Version : %s\nInstall Date : %s\n' "$1" \
        "$(date -d '+1 day' '+%Y-%m-%d %H:%M:%S')"
}

assert_no_u() { # $1 = dir, $2 = label
    if grep -q -- 'pacman -U' "$1/pacman.log" 2>/dev/null; then
        printf '%s: pacman -U ran although the install should have been skipped:\n' "$2" >&2
        cat "$1/pacman.log" >&2
        exit 1
    fi
}

assert_u() { # $1 = dir, $2 = label
    if ! grep -q -- 'pacman -U' "$1/pacman.log" 2>/dev/null; then
        printf '%s: pacman -U never ran:\n' "$2" >&2
        cat "$1/pacman.log" 2>/dev/null >&2 || true
        exit 1
    fi
    if ! grep -F 'p1-1.0.0-1-any.pkg.tar.zst' "$1/pacman.log" >/dev/null; then
        printf '%s: pacman -U ran without the built archive: %s\n' "$2" \
            "$(cat "$1/pacman.log")" >&2
        exit 1
    fi
}

# Case G: resume with -s -i: the build is skipped AND the already-installed
# package is not reinstalled.
dir_g="$fixture/case-g"
make_case_workspace "$dir_g"
builder_args=(p1)
if ! run_case "$dir_g"; then # first run: build only (no -i)
    printf 'case G: initial build failed:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
builder_args=(-s -i p1)
if ! run_case "$dir_g" GSA_FAKE_QP='p1 1.0.0-1' \
    "GSA_FAKE_QI=$(fresh_qi 1.0.0-1)"; then
    printf 'case G: -s -i resume failed:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
g_runs=$(grep -c '^run$' "$dir_g/makepkg.count" 2>/dev/null || true)
if [[ "$g_runs" != 1 ]]; then
    printf 'case G: -s did not skip the build (makepkg ran %s times):\n%s\n' \
        "$g_runs" "$FIXTURE_OUTPUT" >&2
    exit 1
fi
assert_no_u "$dir_g" 'case G'
if ! grep -rq 'already installed' "$dir_g/state" 2>/dev/null &&
    ! grep -q 'already installed' <<<"$FIXTURE_OUTPUT"; then
    printf 'case G: skip-install message missing from log and output:\n%s\n' \
        "$FIXTURE_OUTPUT" >&2
    exit 1
fi

# Case H: -s -fi — the build is still skipped, but the install is forced.
dir_h="$fixture/case-h"
make_case_workspace "$dir_h"
builder_args=(p1)
if ! run_case "$dir_h"; then # first run: build only (no -i)
    printf 'case H: initial build failed:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
builder_args=(-s -fi p1)
if ! run_case "$dir_h" GSA_FAKE_QP='p1 1.0.0-1' \
    "GSA_FAKE_QI=$(fresh_qi 1.0.0-1)"; then
    printf 'case H: -s -fi resume failed:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
h_runs=$(grep -c '^run$' "$dir_h/makepkg.count" 2>/dev/null || true)
if [[ "$h_runs" != 1 ]]; then
    printf 'case H: -s did not skip the build (makepkg ran %s times):\n%s\n' \
        "$h_runs" "$FIXTURE_OUTPUT" >&2
    exit 1
fi
assert_u "$dir_h" 'case H'

# ─── Section 5: unknown version metadata means no archive is eligible ─────
# (inventory KEEP cell "unknown-version refusal": an unversioned archive must
# not broaden discovery and must never be installed). The engine excludes an
# archive whose .PKGINFO carries no version from discovery entirely.
ws="$fixture/unknown-version"
make_workspace "$ws" 1 2 low
write_engine_stubs "$ws" "$ws/db"
add_package "$ws" p1 $'pkgrel=1\narch=(any)'
make_pkg_archive "$ws/packages/p1/p1-1.0.0-1-any.pkg.tar.zst" p1 p1 '' 1
: >"$ws/pacman.log"
run_inst "$ws" -Ua --state-dir "$ws/state-a" --config "$ws/pacman.conf"
[ "$FIXTURE_RC" = 0 ] ||
    fail "J: -Ua must treat an unknown-version archive as ineligible (no-op, rc 0), got $FIXTURE_RC: $FIXTURE_OUTPUT"
[ "$(record_scalar outcome)" = success ] ||
    fail "J: the empty force plan must record success, not a failure: $FIXTURE_OUTPUT"
record_section plan | grep -Fx -- '- noop empty-list' >/dev/null ||
    fail "J: the unknown-version archive must surface as the empty-list noop row: $FIXTURE_OUTPUT"
[ "$(pacman_mut_count "$ws/pacman.log")" = 0 ] ||
    fail "J: -Ua installed an archive despite its missing version metadata:" "$ws/pacman.log"
# the sharp half: with a versioned neighbour present, only the neighbour
# installs — the unversioned archive is never added to the transaction
make_pkg_archive "$ws/packages/p1/other-2.0.0-1-any.pkg.tar.zst" p1 other 2.0.0 1
: >"$ws/pacman.log"
run_inst "$ws" -Ua --state-dir "$ws/state-b" --config "$ws/pacman.conf"
[ "$FIXTURE_RC" = 0 ] || fail "J2: -Ua over one eligible archive must succeed: $FIXTURE_OUTPUT"
[ "$(txn_count "$ws/pacman.log")" = 1 ] ||
    fail "J2: want exactly one transaction:" "$ws/pacman.log"
txn_argv "$ws/pacman.log" | grep -F -- 'other-2.0.0-1-any.pkg.tar.zst' >/dev/null ||
    fail "J2: the eligible archive was not installed:" "$ws/pacman.log"
if txn_argv "$ws/pacman.log" | grep -F -- 'p1-1.0.0-1-any.pkg.tar.zst' >/dev/null; then
    fail "J2: an unknown-version archive rode along in the transaction:" "$ws/pacman.log"
fi

# ─── Section 6: split-output set completeness (inventory KEEP cell
# "split-set completeness"; DEVIATION 4 for the force-path change) ────────
# Installing a SUBSET of a split recipe's outputs is a silent wrong claim:
# the expected set comes from the committed .SRCINFO's pkgname lines
# (crates/gsa-install/src/lib.rs discover_recipe) and a partial set refuses
# by name, never half-installs.

make_split_ws() { # $1 = dir, $2 = 1 (drop the second output at build time)
    local ws=$1 drop=${2:-0}
    make_workspace "$ws" 1 2 low
    write_engine_stubs "$ws" "$ws/db"
    add_package "$ws" p1 $'pkgname=(p1 p1-extra)\npkgver=1.0.0\npkgrel=1\narch=(any)'
    printf '%s\n' 'pkgbase = p1' 'pkgname = p1' 'pkgname = p1-extra' \
        'pkgver = 1.0.0' 'pkgrel = 1' >"$ws/packages/p1/.SRCINFO"
    if [ "$drop" = 1 ]; then
        cat >"$ws/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
stage="$PWD/.stage-p1"
mkdir -p "$stage"
{ printf 'pkgbase = p1\npkgname = p1\npkgver = 1.0.0\npkgrel = 1\narch = any\n'; } >"$stage/.PKGINFO"
tar --zstd -cf "$PWD/p1-1.0.0-1-any.pkg.tar.zst" -C "$stage" .PKGINFO
rm -rf "$stage"
exit 0
EOF
        chmod +x "$ws/bin/makepkg"
    fi
}

# S1: a complete set installs every output in the ONE transaction.
ws="$fixture/split-complete"
make_split_ws "$ws"
make_pkg_archive "$ws/packages/p1/p1-1.0.0-1-any.pkg.tar.zst" p1 p1 1.0.0 1
make_pkg_archive "$ws/packages/p1/p1-extra-1.0.0-1-any.pkg.tar.zst" p1 p1-extra 1.0.0 1
: >"$ws/pacman.log"
run_inst "$ws" -Ua --state-dir "$ws/state" --config "$ws/pacman.conf"
[ "$FIXTURE_RC" = 0 ] || fail "S1: -Ua failed on a complete split set: $FIXTURE_OUTPUT"
[ "$(txn_count "$ws/pacman.log")" = 1 ] ||
    fail "S1: the complete set must transact in ONE pacman -U, got $(txn_count "$ws/pacman.log"):" "$ws/pacman.log"
for out in p1-1.0.0-1-any.pkg.tar.zst p1-extra-1.0.0-1-any.pkg.tar.zst; do
    txn_argv "$ws/pacman.log" | grep -F -- "$out" >/dev/null ||
        fail "S1: the transaction did not receive $out:" "$ws/pacman.log"
done

# S2: a PARTIAL set refuses by name and installs NOTHING (DEVIATION 4: the
# fish-era exclusion+no-op became the fail-closed §E.3 `refuse partial-set`).
ws="$fixture/split-partial"
make_split_ws "$ws" 1
make_pkg_archive "$ws/packages/p1/p1-1.0.0-1-any.pkg.tar.zst" p1 p1 1.0.0 1
: >"$ws/pacman.log"
run_inst "$ws" -Ua --state-dir "$ws/state" --config "$ws/pacman.conf"
[ "$FIXTURE_RC" = 3 ] ||
    fail "S2: a partial set must refuse (rc 3), got $FIXTURE_RC: $FIXTURE_OUTPUT"
[ "$(record_scalar outcome)" = refused ] ||
    fail "S2: the run must record outcome refused: $FIXTURE_OUTPUT"
record_section plan | grep -Fx "p1 refused partial-set $ws/packages/p1 p1-extra" >/dev/null ||
    fail "S2: the refusal row must name the recipe dir and the missing output: $FIXTURE_OUTPUT"
record_section outcome | grep -Fx "p1 never-started - - install-refused partial-set $ws/packages/p1 p1-extra" >/dev/null ||
    fail "S2: the outcome row must carry the named install-refused reason: $FIXTURE_OUTPUT"
[ "$(pacman_mut_count "$ws/pacman.log")" = 0 ] ||
    fail "S2: a refused plan installed something:" "$ws/pacman.log"

# S2b: the same refusal through `gsa -S` (rr2-parseable record; the
# tests/resume-command.sh plan-refusal pin): outcome refused rc 3, the row
# names the omission, and nothing transacts.
ws="$fixture/split-partial-s"
make_split_ws "$ws" 1
: >"$ws/pacman.log"
run_inst "$ws" -S --leaf --config "$ws/pacman.conf" p1
[ "$FIXTURE_RC" = 3 ] ||
    fail "S2b: -S over a partial set must refuse (rc 3), got $FIXTURE_RC: $FIXTURE_OUTPUT"
rr2_body <<<"$FIXTURE_OUTPUT" >/dev/null || fail "S2b: no complete format: 2 run record: $FIXTURE_OUTPUT"
[ "$(rr2_scalar outcome <<<"$FIXTURE_OUTPUT")" = refused ] ||
    fail "S2b: the run must record outcome refused: $FIXTURE_OUTPUT"
[ "$(rr2_scalar rc <<<"$FIXTURE_OUTPUT")" = 3 ] ||
    fail "S2b: the record's rc scalar must be 3: $FIXTURE_OUTPUT"
[ "$(rr2_outcome p1 reason <<<"$FIXTURE_OUTPUT")" = "install-refused partial-set $ws/packages/p1 p1-extra" ] ||
    fail "S2b: p1's row must name the partial-set refusal: $FIXTURE_OUTPUT"
[ "$(pacman_mut_count "$ws/pacman.log")" = 0 ] ||
    fail "S2b: the surviving output must never half-install:" "$ws/pacman.log"

# ─── Section 7 (R-F37): the freshness compare is NANOSECOND, not second ───
# The install date is second-granular, so a second-equality compare skipped a
# same-version rebuild whose archive was written mid-second AFTER the
# install instant. Doubt installs: an archive newer by nanoseconds must
# install; an install genuinely at-or-after the archive still skips.
gsa_db_reset
f37_arch="$fixture/gsa-archives/p1-f37.pkg.tar.zst"
make_pkg_archive "$f37_arch" p1 p1 1.0.0 1
f37_db=$(db_install "$fixture/gsa-db" p1 "$(fullver '' 1.0.0 1)")
touch -d '@1700000000' "$f37_db"

# Same second, archive half a second AFTER the install instant -> install.
# The old second-equality compare reported this as fresh and skipped it.
touch -d '@1700000000.5' "$f37_arch"
gsa_decide checked "$f37_arch"
assert_decisions 'F37: ns-newer archive inside the install second must install' 0 <<'EOF'
p1 install ok
EOF

# Archive exactly at the install instant -> the one equality that skips.
touch -d '@1700000000' "$f37_arch"
gsa_decide checked "$f37_arch"
assert_decisions 'F37: an archive at the install instant still skips' 0 <<'EOF'
p1 skip already-current
EOF

# Archive a second earlier (ns before the install) -> still skips.
touch -d '@1699999999.5' "$f37_arch"
gsa_decide checked "$f37_arch"
assert_decisions 'F37: an older archive with a fresher install still skips' 0 <<'EOF'
p1 skip already-current
EOF

# ─── Section 8 (R-F22): a spaced archive path survives the row codec ──────
# A §E.2 install row carries no path (reason key `ok`), so path survival
# pins as the correct decision computed over the spaced argv — a split path
# would be a malformed-archive rc 2, not a plan.
mkdir -p "$fixture/gsa archives"
space_arch="$fixture/gsa archives/p1 with space-1.0.0-1-any.pkg.tar.zst"
make_pkg_archive "$space_arch" p1 p1 1.0.0 1
gsa_db_reset
gsa_decide checked "$space_arch"
assert_decisions 'R-F22: the install row keeps a spaced path intact' 0 <<'EOF'
p1 install ok
EOF
touch -d '+1 day' "$(db_install "$fixture/gsa-db" p1 "$(fullver '' 1.0.0 1)")"
gsa_decide checked "$space_arch"
assert_decisions 'R-F22: the skip row keeps a spaced path intact' 0 <<'EOF'
p1 skip already-current
EOF

# ─── Section 9: refusal classes (inventory KEEP cell "refusal classes";
# DEVIATION 3 for the retired case-K trigger) ─────────────────────────────
# Damaged archive metadata is fail-closed by name and never installs:
# `refuse discover-failed` when no name authority exists, `skip
# unreadable-pkginfo` when a committed .SRCINFO establishes the names
# (rule 25(h): never probed, never transacted).

# K': a damaged archive handed to -U directly -> refuse discover-failed,
# pacman-free end to end.
ws="$fixture/damaged"
make_workspace "$ws" 1 2 low
write_engine_stubs "$ws" "$ws/db"
add_package "$ws" p1 $'pkgver=1.0.0\npkgrel=1\narch=(any)'
printf 'not a tarball\n' >"$ws/packages/p1/p1-1.0.0-1-any.pkg.tar.zst"
: >"$ws/pacman.log"
run_inst "$ws" -U --state-dir "$ws/state" --config "$ws/pacman.conf" \
    "$ws/packages/p1/p1-1.0.0-1-any.pkg.tar.zst"
[ "$FIXTURE_RC" = 3 ] ||
    fail "K': a damaged archive must refuse (rc 3), got $FIXTURE_RC: $FIXTURE_OUTPUT"
[ "$(record_scalar outcome)" = refused ] ||
    fail "K': the run must record outcome refused: $FIXTURE_OUTPUT"
record_section plan | grep -Fx -- "- refused discover-failed $ws/packages/p1/p1-1.0.0-1-any.pkg.tar.zst" >/dev/null ||
    fail "K': the refusal row must name the damaged archive: $FIXTURE_OUTPUT"
record_section outcome | grep -F -- "install-refused discover-failed $ws/packages/p1/p1-1.0.0-1-any.pkg.tar.zst" >/dev/null ||
    fail "K': the outcome row must carry the named refusal reason: $FIXTURE_OUTPUT"
[ "$(pacman_mut_count "$ws/pacman.log")" = 0 ] ||
    fail "K': a refusing plan reached pacman:" "$ws/pacman.log"

# K'': the same refusal class at the seam (§E.3 `refuse discover-failed`).
damaged="$fixture/damaged-1.0.0-1-any.pkg.tar.zst"
printf 'not a tarball\n' >"$damaged"
gsa_db_reset
gsa_decide checked "$damaged"
assert_decisions 'K2: damaged archive at the seam refuses discover-failed' 1 <<'EOF'
- refuse discover-failed
EOF

# K''': with names established by a committed .SRCINFO the damaged archive
# is SKIPPED as unreadable, never refused and never probed (rule 25(h)).
mkdir -p "$fixture/named/p1"
printf '%s\n' 'pkgbase = p1' 'pkgname = p1' 'pkgname = p1-extra' >"$fixture/named/p1/.SRCINFO"
named_damaged="$fixture/named/p1/p1-1.0.0-1-any.pkg.tar.zst"
cp "$damaged" "$named_damaged"
gsa_decide checked "$named_damaged"
assert_decisions 'K3: named damaged archive skips unreadable-pkginfo' 0 <<'EOF'
p1 skip unreadable-pkginfo
EOF

# R-F25: -Ua must not silently install a shrunken set. One recipe's
# discovery is damaged (partial split set) while another has a complete
# built set: "install everything" may not install the evaluable subset and
# report success — the plan refuses the omission by name and the refusing
# plan is pacman-free end to end (rule 25(h); stronger than the old pin that
# only barred the subset).
ws="$fixture/ia-shrink"
make_workspace "$ws" 1 2 low
write_engine_stubs "$ws" "$ws/db"
add_package "$ws" p1 $'pkgver=1.0.0\npkgrel=1\narch=(any)'
add_package "$ws" p2 $'pkgname=(p2 p2-extra)\npkgver=1.0.0\npkgrel=1\narch=(any)'
printf '%s\n' 'pkgbase = p2' 'pkgname = p2' 'pkgname = p2-extra' \
    'pkgver = 1.0.0' 'pkgrel = 1' >"$ws/packages/p2/.SRCINFO"
make_pkg_archive "$ws/packages/p1/p1-1.0.0-1-any.pkg.tar.zst" p1 p1 1.0.0 1
make_pkg_archive "$ws/packages/p2/p2-1.0.0-1-any.pkg.tar.zst" p2 p2 1.0.0 1
: >"$ws/pacman.log"
run_inst "$ws" -Ua --state-dir "$ws/state" --config "$ws/pacman.conf"
[ "$FIXTURE_RC" = 3 ] ||
    fail "R-F25: -Ua must refuse over a shrunken set (never install the subset), got $FIXTURE_RC: $FIXTURE_OUTPUT"
[ "$(record_scalar outcome)" = refused ] ||
    fail "R-F25: the run must record refusal, never success: $FIXTURE_OUTPUT"
record_section plan | grep -Fx "p2 refused partial-set $ws/packages/p2 p2-extra" >/dev/null ||
    fail "R-F25: the refusal must name p2's discovery failure and the missing output: $FIXTURE_OUTPUT"
if record_section plan | grep -Fx -- '- noop empty-list' >/dev/null; then
    fail "R-F25: a non-empty set must not be reported as nothing-eligible: $FIXTURE_OUTPUT"
fi
[ "$(pacman_mut_count "$ws/pacman.log")" = 0 ] ||
    fail "R-F25: a refusing plan installed the evaluable subset:" "$ws/pacman.log"

# Wave-1 follow-up: the partial-set refusal is its own named row
# (`refuse partial-set`), never a fall-through to `refuse empty-list` —
# asserted above at both -Ua and -S; the row MEANING is the §E.3 spelling.

# ─── Section 10: the emit seam — one decision, one rendering ──────────────
# D-F13: the empty-set refusal renders through the ONE decision seam: the
# §E.2 plan row and the §H outcome row carry the SAME decision/reason pair
# (`refused empty-list` / `install-refused empty-list`), exactly once each —
# the old unified-wording pin re-pins as this cross-rendering key equality
# (§L.3: never prose).
ws="$fixture/empty-render"
make_workspace "$ws" 1 2 low
write_engine_stubs "$ws" "$ws/db"
add_package "$ws" p1 $'pkgrel=1\narch=(any)'
make_pkg_archive "$ws/packages/p1/p1-1.0.0-1-any.pkg.tar.zst" p1 p1 '' 1
: >"$ws/pacman.log"
run_inst "$ws" -U --state-dir "$ws/state" --config "$ws/pacman.conf" p1
[ "$FIXTURE_RC" = 3 ] ||
    fail "D-F13: a checked empty plan must refuse (rc 3), got $FIXTURE_RC: $FIXTURE_OUTPUT"
plan_rows=$(record_section plan)
out_rows=$(record_section outcome)
[ "$(printf '%s\n' "$plan_rows" | grep -cFx -- '- refused empty-list')" = 1 ] ||
    fail "D-F13: the empty refusal must render exactly once in the plan rows: $plan_rows"
[ "$(printf '%s\n' "$out_rows" | grep -cF -- 'install-refused empty-list')" = 1 ] ||
    fail "D-F13: the empty refusal must render exactly once in the outcome rows: $out_rows"
# one decision, one seam: both renderings carry the same reason KEY
plan_key=$(printf '%s\n' "$plan_rows" | awk '$1 == "-" && $2 == "refused" { print $3 }')
[ "$plan_key" = empty-list ] ||
    fail "D-F13: the plan row's reason key must be empty-list, got: $plan_key"
printf '%s\n' "$out_rows" | grep -F 'install-refused empty-list' >/dev/null ||
    fail "D-F13: the outcome rendering lost the empty-list reason key: $out_rows"
[ "$(pacman_mut_count "$ws/pacman.log")" = 0 ] ||
    fail "D-F13: the empty refusal reached pacman:" "$ws/pacman.log"

# D-F14: a mixed skip set shows EVERY version, not one row's: two outputs
# of one split recipe (same pkgbase — the §E.2 subject) with DIFFERENT
# installed versions in one decision set — each row names its own
# already-current version (the old note printed the last row's version for
# both; the version detail is the pin, so full rows are compared).
gsa_db_reset
d14a="$fixture/gsa-archives/p1-1.0.0-1-any.pkg.tar.zst"
d14b="$fixture/gsa-archives/p1-extra-2.0-1-any.pkg.tar.zst"
make_pkg_archive "$d14a" p1 p1 1.0.0 1
make_pkg_archive "$d14b" p1 p1-extra 2.0 1
touch -d '+1 day' "$(db_install "$fixture/gsa-db" p1 "$(fullver '' 1.0.0 1)")"
touch -d '+1 day' "$(db_install "$fixture/gsa-db" p1-extra "$(fullver '' 2.0 1)")"
gsa_decide checked "$d14a" "$d14b"
[ "$FIXTURE_RC" = 0 ] || fail "D-F14: an rc 0 plan was expected: $FIXTURE_OUTPUT"
assert_rows 'D-F14: each skip row names its own version' <<EOF
p1 skip already-current $(fullver '' 1.0.0 1)
p1 skip already-current $(fullver '' 2.0 1)
EOF

# ─── Section 11: the empty-plan decision sets (old I6/I7) ─────────────────
# §E.3's `empty-list` spelling: `refuse` under checked, `noop` under force
# (`-Ua`, zero eligible archives). §D.1's seam grammar takes <archive…> and
# cannot express an empty plan (a zero-archive call is §E.5 bad usage), so
# the rows come from the -U family's own plan entries.
ws="$fixture/empty-plan"
make_workspace "$ws" 1 2 low
write_engine_stubs "$ws" "$ws/db"
add_package "$ws" p1 $'pkgver=1.0.0\npkgrel=1\narch=(any)'
: >"$ws/pacman.log"
run_inst "$ws" -U --dry-run --state-dir "$ws/state" --config "$ws/pacman.conf" p1
assert_rows 'I6 (checked, empty list)' <<'EOF'
- refuse empty-list
EOF
run_inst "$ws" -Ua --dry-run --state-dir "$ws/state" --config "$ws/pacman.conf"
assert_rows 'I7 (force, empty list)' <<'EOF'
- noop empty-list
EOF
# the seam's own zero-archive contract is §E.5 bad usage: rc 2, no rows
gsa_decide checked
assert_decisions 'I6/I7 seam: a zero-archive argument list is bad usage' 2 </dev/null
gsa_decide force
assert_decisions 'I6/I7 seam: a zero-archive argument list is bad usage' 2 </dev/null

# The seam touches nothing (§D.1): the fail-stubs in $fixture/gsa-bin abort
# with a loud message on any pacman/sudo contact, and every seam run's rc
# contract above would have failed with it.

printf 'install archive guard fixture: PASS\n'
