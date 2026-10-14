#!/usr/bin/env bash
set -euo pipefail

# ABI-drift guard layer 3 — the install-time fatal provide-diff refusal
# (the gsa provide-diff gate, crates/gsa-abi/src/rows.rs, an install-plan
# step beside the PGO gate; the port of build-all.fish abi_provide_refusals).
# Through the hidden `gsa --install-decide <checked|force> <archive…>` seam
# (§D.1 — no pacman transaction, no sudo, no flock, no makepkg) and the
# force-mode install executor (`gsa -Uf`, §B.6) this pins:
#
#   A. a bare soname provide that MOVES against the installed database
#      (libgreet.so=1-64 → libgreet.so=2-64, same pkgname) while the
#      installed consumer closure is NOT in the transaction → silent
#      `refuse abi-soname` + `refuse abi-consumer` rows, rc 1 (both modes);
#   B. closure complete: the consumer's archive rides in the same
#      transaction → the covered consumer is never named
#      (FISH-DRIVEN clean-plan meaning — DEVIATION 2);
#   C. nothing to protect: the consumer is not installed → the consumer
#      rows are absent (FISH-DRIVEN clean-plan meaning — DEVIATION 2);
#   D. no provide diff (same soname versions) → rc 0, `install` rows;
#   E. a DISAPPEARING provide (built archive drops the soname entirely) →
#      `refuse abi-soname … <installed-ver> -` + consumer rows, rc 1;
#   F. fresh install (the pkgname is not installed at all) → rc 0: nothing
#      installed can lose a provide;
#   G. the force branch does NOT bypass the gate: the REAL force-mode
#      install executor (`gsa -Uf`) renders the same refusal into the run
#      record (`install-refused …` outcome rows, outcome: refused, rc 3)
#      and aborts before pacman -U;
#   H. a spaced archive path survives into the decision row intact
#      (R-F22's meaning, re-pinned on the row's reason detail);
#   I. Stock→house swap (the run #31 blind spot): the archive's pkgname is
#      NOT installed but its stock counterpart (stock_name) IS, with a
#      drifted soname surface and an uncovered consumer closure → the SAME
#      `refuse abi-soname` + `refuse abi-consumer` rows (the subject stays
#      the ARCHIVE's pkgbase; the installed side comes from the counterpart),
#      rc 1, and zero mutating invocations (no pacman -U, no sudo — the
#      decision half's only traffic is the read-only local-DB read);
#   J. the swap with an IDENTICAL soname surface is a clean pass even with
#      the consumer closure open — only the surface MOVING strands consumers.
#      (The double-fresh shape — neither the pkgname nor the stock
#      counterpart installed — is case F: same clean plan.)
#   K. in-run repair coverage (2026-10-07, run #48 wall): the surface
#      consumer scheduled strictly AFTER the provider in the exported run
#      order (_GSA_RUN_ORDER — run_lanes' topological selection) is rebuilt
#      and reinstalled by THIS run, so the move lands with a repair: clean
#      plan carrying the non-refusal `repair` row the executor turns into
#      the forced-rebuild marker (FISH-DRIVEN — DEVIATION 1);
#   L. the consumer scheduled BEFORE the provider in the run order → the
#      usual refusals (nothing later repairs it) — the run-order
#      sensitivity is FISH-DRIVEN (DEVIATION 1);
#   M. the consumer absent from the run order → the usual refusals (the run
#      never rebuilds it) — FISH-DRIVEN (DEVIATION 1);
#   N. the REAL -i executor cycle: a run whose selection orders the consumer
#      after the provider plans `repair`, records the forced-rebuild marker
#      under $GSA_STATE_DIR/abi-repair/ BEFORE pacman -U (the stub snapshots
#      the marker dir at every transaction), renders the note into the
#      package log, and consumes the marker when the consumer's own install
#      lands (FISH-DRIVEN — DEVIATION 1);
#   O. STOCK-SIDE pinner (2026-10-07, run #49 wall #2): an OUT-OF-TREE
#      installed package (no workspace recipe) whose declared Depends pins
#      the moving provide EXACTLY (`libgreet.so=1-64`) while the workspace
#      closure is empty. The pre-fix gate planned a CLEAN install — pacman
#      would have refused it in raw noise. The gate must consult the LOCAL
#      DB's reverse deps and refuse with rows naming the pinner and the
#      exact depstring: `refuse abi-stock-pinner <archive> <pinner> <dep>`.
#      The executor half renders that refusal through the REAL force-mode
#      install run (`gsa -Uf`) as a named `install-refused abi-stock-pinner`
#      record row — never an `unrecognized install-plan refusal`;
#   P. the bare-link shape and the split: a stock pinner with `Depends On :
#      libgreet.so` (bare) is named too — a bare linker of a moved soname
#      breaks at runtime exactly like a pin breaks pacman — while a
#      WORKSPACE recipe output carrying the same moving pin in the local DB
#      stays the existing class (`refuse abi-consumer`, link truth) and is
#      never named as a stock-side pinner (the split is FISH-DRIVEN —
#      DEVIATION 3);
#   Q. a stock-side pinner whose OWN archive rides the transaction is
#      covered: pacman re-checks its new depends against the new provides in
#      the same transaction → the pinner is never named (FISH-DRIVEN
#      clean-plan meaning — DEVIATION 2).
#
# Flip notes (docs/gsa-fixture-migration.md row `tests/abi-drift-install.sh`;
# colon line cites below are the PRE-P2 fixture's, as in that inventory):
# The fixture now DRIVES the gsa engine through tests/lib/rr-v2.bash
# (run_engine with GSA_TEST_ENGINE=gsa; hidden seam `gsa --install-decide
# <checked|force> <archive…>`, §D.1). Row framing (REWRITE ≈13, R-5): the
# tab plan_row codec (pre-P2 :89-94) is RETIRED — §E.2 decision rows
# (`<pkgbase> <decision> <reason…>`) are parsed by rr2_decisions into
# (pkgbase, decision, reason-key) tuples and pinned exact-order
# (assert_decisions), with rc per §E.5 (0 plan / 1 refusal / 2 usage —
# decision meanings + rc 0/1 in both modes re-pin on the engine seam).
# argv (REWRITE): the fish `--install-decide` spelling and the `-i`
# executor runs (pre-P2 :266, :410, :719) become `gsa --install-decide` and
# `gsa -Uf` (§B.6); prose (REWRITE, pre-P2 :416, :723) — the package-log
# refusal renderings — re-pin as record-derived `install-refused <reason…>`
# outcome rows (§H.3) with outcome: refused / rc 3 (§G.1). R-1/R-2 (§6):
# this fixture carries no fish source-shape greps and no format: 1 row
# grammar, so nothing of either class remains to retire.
# The executor runs' records parse through the strict rr2_* parser since the
# cutover gap-(a) fix (integer budget scalars, one row per subject); the
# record_scalar/record_section helpers below are thin rr2_* wrappers.
#
# DEVIATION 1 (gap G1, docs/gsa-fixture-migration.md §8.1; inventory KEEP
# cell "repair coverage (:542-663)"): cases K/L/M/N stay FISH-DRIVEN. The
# `repair <arch> <consumer> <provider-id>` row has NO §E.3 form (§8.1) and
# the engine seam cannot express in-run repair coverage at all —
# DecisionContext.later_installs is fixed empty on that path
# (crates/gsa-cli/src/install.rs run_install_decide); the seam's rows for
# the repair state are pinned as the engine actually emits them (K's §E.2
# block) and `_GSA_RUN_ORDER`'s order-sensitivity has no engine surface
# (the seam is order-blind). K's fish row-set check compares the fish
# seam's rows field-wise (tabs normalized) — the retired codec's byte
# framing is gone; §E.2 has no repair decision to re-pin through.
# DEVIATION 2 (inventory KEEP cell "gate semantics (:288-378)" vs
# crates/gsa-abi/src/rows.rs): fish's gate is coverage-aware ("the refusal
# is conditional", build-all.fish abi_provide_refusals) — B/C/Q plan CLEAN
# when nothing is stranded. The engine refuses every drifting bare-soname
# provide UNCONDITIONALLY (`abi-soname` per drifted provide) and coverage
# suppresses only the `abi-consumer`/`abi-stock-pinner` rows. Both sides
# pin their own truth: the clean-plan meanings keep their fish-era pins and
# the engine rows are pinned exactly as emitted (B/C/Q §E.2 blocks).
# DEVIATION 3 (inventory case P split): the engine's stock_pinners scan has
# no workspace filter (crates/gsa-abi/src/rows.rs stock_pinners) — it names
# the workspace output app-git as an `abi-stock-pinner` alongside its
# `abi-consumer` row, where fish keeps workspace pins in the `abi-consumer`
# class only. The engine rows are pinned as emitted (4 rows); the split
# meaning keeps its fish-era pin.
# DEVIATION 4 (inventory new-contract target cell): the target names
# `refuse abi-consumer-uncovered`; the seam emits `refuse abi-consumer`
# (rows.rs; `abi-consumer-uncovered` is the wave planner's under-coverage
# class, §E.3). Rows are pinned as emitted, never as the inventory guessed.
# GAP (tests/lib/rr-v2.bash, out of edit scope): its pre-declared GSA_FAKE_*
# table lacks this fixture's fish-stub knobs (GSA_FAKE_QI_LIBS/_APP/_STOCK,
# GSA_FAKE_APP_INSTALLED, GSA_FAKE_ACCEPT_U, GSA_FAKE_MARKER_SNAPSHOT);
# declared inline via rr2_stub_knob (§D.2) instead.
#
# The fish pacman stub is read-only (-Qi/-Q probes plus the `pacman -Qi --`
# full-dump the stock-pinner query reads, fabricated from GSA_FAKE_QI_ALL);
# every seam case asserts no `pacman -U` ever ran, and the engine seam runs
# against fail-stubs that make any pacman/sudo spawn loud (§D.1). Scratch
# workspaces under $TMPDIR only.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/tests/lib/fixture-lib.bash"
source "$root/tests/lib/rr-v2.bash"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-abi-drift-install.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    printf 'abi-drift-install fixture: %s\n' "$1" >&2
    exit 1
}

# ─── The engine under test: built into the fixture tree (scratch only).
# GSA_TEST_GSA_BIN, when already set to an executable, is that engine (the
# rr-v2.bash run_engine convention) and the scratch build is skipped. ──────
if [ -z "${GSA_TEST_GSA_BIN:-}" ]; then
    cargo build --offline --quiet --target-dir "$tmp/cargo" -p gsa-cli \
        --manifest-path "$gsa_repo_root/Cargo.toml" ||
        fail "cannot build the gsa binary for the fixture"
    GSA_TEST_GSA_BIN="$tmp/cargo/debug/gsa"
fi
[ -x "$GSA_TEST_GSA_BIN" ] || fail "the engine under test is not executable: $GSA_TEST_GSA_BIN"
export GSA_TEST_ENGINE=gsa
export GSA_TEST_GSA_BIN

# Fixture-side stub knobs (§D.2; the GAP note in the header for the table
# that should carry these).
rr2_stub_knob GSA_FAKE_QI_LIBS 'abi-drift-install pacman stub: pacman -Qi answer for libs-git'
rr2_stub_knob GSA_FAKE_QI_APP 'abi-drift-install pacman stub: pacman -Qi answer for app-git'
rr2_stub_knob GSA_FAKE_QI_STOCK 'abi-drift-install pacman stub: pacman -Qi answer for the stock counterpart libs'
rr2_stub_knob GSA_FAKE_APP_INSTALLED 'abi-drift-install pacman stub: app-git -Q/-Ql membership flag'
rr2_stub_knob GSA_FAKE_ACCEPT_U 'abi-drift-install pacman stub: accept -U (marker-snapshot oracle)'
rr2_stub_knob GSA_FAKE_MARKER_SNAPSHOT 'abi-drift-install pacman stub: ABI-repair marker snapshot at transaction time'

# gsa-bin: the engine seam's only subprocess is `pacman-conf DBPath` (the
# local-DB root it reads natively — never the host's /var/lib/pacman).
# pacman/sudo are fail-stubs: nothing in a decision-only run or a refused
# install run may reach them (§D.1 / rule 25(h)).
mkdir -p "$tmp/gsa-db/local" "$tmp/gsa-bin"
cat >"$tmp/gsa-bin/pacman-conf" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = DBPath ] && printf '%s\n' "$tmp/gsa-db"
exit 0
EOF
chmod +x "$tmp/gsa-bin/pacman-conf"
for stub in pacman sudo; do
    cat >"$tmp/gsa-bin/$stub" <<EOF
#!/usr/bin/env bash
printf 'UNEXPECTED $stub in a decision-only run: %s\n' "\$*" >&2
exit 99
EOF
    chmod +x "$tmp/gsa-bin/$stub"
done

# write_elf64_needed FILE SONAME — a minimal section-less ELF64 (ET_DYN)
# carrying exactly one DT_NEEDED (byte layout after the oracle in
# crates/gsa-recipe/src/elf.rs: ehdr | PT_LOAD | PT_DYNAMIC | dyn entries |
# dynstr). This is the FILE truth the engine's link filter reads — the fish
# seam's readelf stub below answers the same DT_NEEDED.
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

# The linked-consumer file truth: app-git's installed record owns this ELF,
# whose DT_NEEDED is libgreet.so.1-64 (the fish stub readelf answers the
# same). The local-DB files entry carries the path minus its leading slash
# (crates/gsa-install/src/localdb.rs reads `/<files-entry>`).
consumer_elf="$tmp/consumer/lib-app-git.so"
mkdir -p "$tmp/consumer"
write_elf64_needed "$consumer_elf" 'libgreet.so.1-64'

# The engine seam's Tier-2 exclusions lookup walks up from each archive
# (crates/gsa-install/src/gates.rs find_repo_exclusions) — shadow the real
# repository's registry with an empty one so the fixture is self-contained.
mkdir -p "$tmp/config"
: >"$tmp/config/abi-exclusions.conf"

# gsa_db NAME VERSION [PROVIDE [DEP [FILE]]] — one fabricated pacman local-DB
# entry (crates/gsa-install/src/localdb.rs reads
# <db-root>/local/<name>-<ver>/{desc,files} natively — the seam is pacman-free;
# the entry dir's mtime IS the install date).
gsa_db_reset() {
    rm -rf "$tmp/gsa-db"
    mkdir -p "$tmp/gsa-db/local"
}
gsa_db() {
    local name=$1 version=$2 provide=${3:-} dep=${4:-} file=${5:-}
    local dir="$tmp/gsa-db/local/$name-$version"
    mkdir -p "$dir"
    {
        printf '%%NAME%%\n%s\n\n' "$name"
        printf '%%VERSION%%\n%s\n\n' "$version"
        printf '%%BASE%%\n%s\n' "$name"
        if [ -n "$provide" ]; then printf '%%PROVIDES%%\n%s\n' "$provide"; fi
        if [ -n "$dep" ]; then printf '%%DEPENDS%%\n%s\n' "$dep"; fi
    } >"$dir/desc"
    if [ -n "$file" ]; then
        printf '%%FILES%%\n%s\n' "$file" >"$dir/files"
    else
        printf '%%FILES%%\n' >"$dir/files"
    fi
}

# The installed-state builders: the provider surface (old 1-64 by default,
# 2-64 when the case declares the new surface), the installed LINKED
# consumer (optionally with a moving pin in its Depends), and the stock
# counterpart `libs`.
gsa_provider() { gsa_db libs-git 1.0.0-1 "libgreet.so=${1:-1-64}"; }
gsa_consumer() { gsa_db app-git 1.0.0-1 'libapp.so=1-64' "${1:-}" "$consumer_elf"; }
gsa_stock() { gsa_db libs 1.0.0-1 "libgreet.so=${1:-1-64}"; }

# gsa_archive NAME [PROVIDE...] — one real .pkg.tar.zst with a COMPLETE
# .PKGINFO (the seam reads archive metadata natively and requires arch=).
# Prints the path.
gsa_archive() {
    local name=$1
    shift
    local stage="$tmp/gsa-stage-$name"
    rm -rf "$stage"
    mkdir -p "$stage" "$tmp/gsa-archives"
    {
        printf 'pkgname = %s\n' "$name"
        printf 'pkgbase = %s\n' "$name"
        printf 'pkgver = 1.0.0\n'
        printf 'pkgrel = 1\n'
        printf 'arch = x86_64\n'
        local line
        for line in "$@"; do printf 'provides = %s\n' "$line"; done
    } >"$stage/.PKGINFO"
    tar --zstd -cf "$tmp/gsa-archives/$name-1.0.0-1-x86_64.pkg.tar.zst" \
        -C "$stage" .PKGINFO
    rm -rf -- "$stage"
    printf '%s\n' "$tmp/gsa-archives/$name-1.0.0-1-x86_64.pkg.tar.zst"
}

# gsa_decide MODE [ARCHIVE...] — the §E.2 seam over the fabricated state
# (capture in FIXTURE_OUTPUT/FIXTURE_RC, like run_builder).
gsa_decide() {
    local mode=$1
    shift
    local PATH="$tmp/gsa-bin:$PATH"
    run_engine "$ws" --install-decide "$mode" "$@"
}

# gsa_install ARCHIVE... — the engine's force-mode install executor
# (`gsa -Uf`, §B.6): the real run path that renders `install-refused …`
# record rows and aborts before pacman. GSA_STATE_DIR is engine INPUT here
# (the side-car run history lands under it — never /var/lib/gsa).
gsa_install() {
    local PATH="$tmp/gsa-bin:$PATH" GSA_STATE_DIR="$ws/state"
    export GSA_STATE_DIR
    run_engine "$ws" -Uf "$@"
}

# decision_rows — the §E.2 decision rows of one engine capture (the seam
# prints rows alone), engine diagnostics dropped.
decision_rows() {
    awk '/^--- run record begin ---/ || /^Build run: / { exit } !/^gsa: / && NF { print }'
}

# assert_decisions LABEL RC — the §E.2 re-pin (R-5): $FIXTURE_OUTPUT's
# normalized (pkgbase, decision, reason-key) rows exactly as given on stdin,
# in plan order, plus the seam's rc contract (§E.5: 0 = no refuse row /
# 1 = >=1 refuse row / 2 = bad usage and no rows) and its pacman-free
# contract (the fail-stubs would print UNEXPECTED if spawned).
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
    if grep -Fq 'UNEXPECTED' <<<"$FIXTURE_OUTPUT"; then
        fail "$label: the seam reached pacman/sudo (§D.1): $FIXTURE_OUTPUT"
    fi
}

# seam_row_has LABEL NEEDLE — some §E.2 row's reason DETAIL carries NEEDLE
# (record-derived: §7 strips detail only from the normalized tuple, never
# from the record the fixture reads).
seam_row_has() {
    local label=$1 needle=$2
    grep -Fq "$needle" <<<"$(decision_rows <<<"$FIXTURE_OUTPUT")" ||
        fail "$label: no decision row carries '$needle': $FIXTURE_OUTPUT"
}

# record_scalar KEY / record_section plan|outcome / record_row_has — the
# machine block of a -U run capture, through the STRICT `format: 2` parser
# (rr2_body): `-U` records are §H.2-conformant since the cutover gap-(a) fix
# (integer budget scalars, one row per subject).
record_scalar() {
    rr2_scalar "$1" <<<"$FIXTURE_OUTPUT"
}
record_section() {
    case $1 in
    plan) rr2_plan_rows <<<"$FIXTURE_OUTPUT" ;;
    outcome) rr2_outcome_rows <<<"$FIXTURE_OUTPUT" ;;
    *) fail "record_section: unknown section $1" ;;
    esac
}
record_row_has() {
    local label=$1 needle=$2
    grep -Fq "$needle" <<<"$(record_section outcome)" ||
        fail "$label: no outcome row carries '$needle': $FIXTURE_OUTPUT"
}

# assert_refused_install LABEL — a refused install run's record contract:
# rc 3 / outcome: refused (§G.1), every outcome row an `install-refused …`
# never-started row (§H.3), and the refusal reached no pacman/sudo (the
# fail-stubs print UNEXPECTED when spawned).
assert_refused_install() {
    local label=$1 rows
    [[ $FIXTURE_RC == 3 ]] ||
        fail "$label: a refused install run must exit 3 (§G.1), got $FIXTURE_RC: $FIXTURE_OUTPUT"
    [[ $(record_scalar outcome) == refused ]] ||
        fail "$label: record outcome is '$(record_scalar outcome)', want refused: $FIXTURE_OUTPUT"
    [[ $(record_scalar rc) == 3 ]] ||
        fail "$label: record rc is '$(record_scalar rc)', want 3: $FIXTURE_OUTPUT"
    rows=$(record_section outcome)
    [[ -n $rows ]] || fail "$label: the record has no outcome rows: $FIXTURE_OUTPUT"
    awk '$2 != "never-started" || $5 != "install-refused" { bad = 1 } END { exit bad }' <<<"$rows" ||
        fail "$label: outcome rows are not install-refused never-started rows: $rows"
    if grep -Fq 'UNEXPECTED' <<<"$FIXTURE_OUTPUT"; then
        fail "$label: the refused run reached pacman/sudo (rule 25(h)): $FIXTURE_OUTPUT"
    fi
}

checks=0

# make_archive DIR PKGNAME PROVIDES-LINE... — a makepkg-shaped archive with
# just .PKGINFO (the gate reads metadata, never payload bytes).
make_archive() {
    local dir=$1 name=$2
    shift 2
    local stage="$tmp/stage-$name"
    rm -rf -- "$stage"
    mkdir -p "$stage"
    {
        printf 'pkgname = %s\n' "$name"
        printf 'pkgver = 1.0.0-1\n'
        local line
        for line in "$@"; do
            printf 'provides = %s\n' "$line"
        done
    } >"$stage/.PKGINFO"
    tar --zstd -cf "$dir/packages/$name/$name-1.0.0-1-x86_64.pkg.tar.zst" -C "$stage" .
    rm -rf -- "$stage"
}

write_srcinfo() {
    local dir=$1 base=$2
    shift 2
    {
        printf 'pkgbase = %s\n' "$base"
        printf 'pkgname = %s\n' "$base"
        printf '%s\n' "$@"
    } >"$dir/.SRCINFO"
}

ws="$tmp/ws"
make_workspace "$ws" 1 2 low
install_fish_oracle "$ws"
make_install_conf "$ws/pacman.conf" # this run's IgnorePkg registration target (never the host's)
add_package "$ws" libs-git "$gsa_meta_any"
add_package "$ws" app-git "$gsa_meta_any"
set_topology_record "$ws" app-git git 'libs-git'
write_srcinfo "$ws/packages/libs-git" libs-git $'\tprovides = libgreet.so'
write_srcinfo "$ws/packages/app-git" app-git $'\tdepends = libgreet.so'

# The transaction's archives: provider with the BUMPED auto-versioned provide,
# consumer with a stable one.
libs_arch="$ws/packages/libs-git/libs-git-1.0.0-1-x86_64.pkg.tar.zst"
app_arch="$ws/packages/app-git/app-git-1.0.0-1-x86_64.pkg.tar.zst"
make_archive "$ws" libs-git 'libgreet.so=2-64'
make_archive "$ws" app-git 'libapp.so=1-64'

# The fish pacman stub: read-only probes only. Arguments arrive `pacman -Qi -- NAME`
# (the builder passes `--` before names), so the stub drops `--` before
# reading them. -Qi NAME answers installed provides from GSA_FAKE_QI_LIBS /
# GSA_FAKE_QI_APP (empty = not installed, exit 1 — the conservative
# direction); -Q NAME answers membership from GSA_FAKE_APP_INSTALLED; -U must
# NEVER run in any decide case.
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
        # The full-dump form (`pacman -Qi --`, no target): the local-DB seam
        # abi_local_depend_rows reads (every installed record's Depends On).
        # GSA_FAKE_QI_ALL fabricates those records; unset keeps the
        # pre-existing "no answer" shape (exit 1) so every earlier case's
        # pacman traffic is unchanged.
        [[ -n ${GSA_FAKE_QI_ALL:-} ]] || exit 1
        printf '%s\n' "$GSA_FAKE_QI_ALL"
        exit 0
    fi
    case ${args[1]:-} in
    libs-git)
        [[ -n ${GSA_FAKE_QI_LIBS:-} ]] || exit 1
        printf '%s\n' "$GSA_FAKE_QI_LIBS"
        ;;
    app-git)
        [[ -n ${GSA_FAKE_QI_APP:-} ]] || exit 1
        printf '%s\n' "$GSA_FAKE_QI_APP"
        ;;
    libs)
        # The STOCK counterpart of libs-git — the swap path's comparison
        # surface (empty = nothing installed for it = true fresh install).
        [[ -n ${GSA_FAKE_QI_STOCK:-} ]] || exit 1
        printf '%s\n' "$GSA_FAKE_QI_STOCK"
        ;;
    *) exit 1 ;;
    esac
    ;;
-Q)
    if [[ ${args[1]:-} == app-git ]]; then
        [[ ${GSA_FAKE_APP_INSTALLED:-0} == 1 ]] && exit 0
    fi
    exit 1
    ;;
-Ql)
    # File listing for the link-truth probe (gate fix v2): one synthetic ELF
    # path per installed member; the readelf stub answers its DT_NEEDED from
    # the NAME, so the path only has to identify the member (the engine's
    # file truth is the local-DB files entry, not this stub).
    if [[ ${args[1]:-} == app-git && ${GSA_FAKE_APP_INSTALLED:-0} == 1 ]]; then
        printf '%s /usr/lib/lib-app-git.so\n' "${args[1]}"
        exit 0
    fi
    exit 1
    ;;
-Qp) exit 1 ;;
-U)
    if [[ ${GSA_FAKE_ACCEPT_U:-0} == 1 ]]; then
        # N's oracle: snapshot the pending ABI-repair markers at transaction
        # time — the contract is "written before the move lands, consumed
        # only after the marked recipe's own install".
        if [[ -n ${GSA_FAKE_MARKER_SNAPSHOT:-} ]]; then
            {
                printf 'U:%s:' "$*"
                ls "${GSA_STATE_DIR:-/nonexistent}/abi-repair" 2>/dev/null | tr '\n' ' '
                printf '\n'
            } >>"$GSA_FAKE_MARKER_SNAPSHOT"
        fi
        exit 0
    fi
    printf 'UNEXPECTED pacman -U in a decide-only run\n' >&2
    exit 99
    ;;
esac
exit 0
EOF
chmod +x "$ws/bin/pacman"

# The stub readelf: DT_NEEDED truth for the fish link filter. app-git LINKS
# the provider's soname (`libgreet.so.1-64`) — the fixture's installed
# consumer is exactly the class the gate protects; a consumer that never
# references the moving soname must not gate (pinned in tests/abi-batch-policy.sh G5).
cat >"$ws/bin/readelf" <<'EOF'
#!/usr/bin/env bash
set -u
for a in "$@"; do
    [[ $a == -* ]] && continue
    printf 'File: %s\n' "$a"
    case $a in
    *app-git*)
        printf ' 0x0000000000000001 (NEEDED)             Shared library: [libgreet.so.1-64]\n'
        ;;
    *)
        printf ' 0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]\n'
        ;;
    esac
done
exit 0
EOF
chmod +x "$ws/bin/readelf"

# decide MODE [ARCHIVE...] — the FISH seam for the fish-driven cases
# (DEVIATION 1-3 sites). Stdout only (the rows) in FIXTURE_OUTPUT; stderr is
# kept apart so user fish-config noise can never disturb the row assertions
# (install-conflict-ask's convention).
decide() {
    set +e
    FIXTURE_OUTPUT=$(env \
        PATH="$ws/bin:$PATH" \
        GSA_STATE_DIR="$ws/state" \
        _IGNOREPKG_CONF="$ws/pacman.conf" \
        GSA_FAKE_PACMAN_LOG="$ws/pacman.log" \
        GSA_FAKE_QI_LIBS="$GSA_FAKE_QI_LIBS" \
        GSA_FAKE_QI_APP="$GSA_FAKE_QI_APP" \
        GSA_FAKE_QI_STOCK="${GSA_FAKE_QI_STOCK:-}" \
        GSA_FAKE_QI_ALL="${GSA_FAKE_QI_ALL:-}" \
        GSA_FAKE_APP_INSTALLED="$GSA_FAKE_APP_INSTALLED" \
        _GSA_RUN_ORDER="${_GSA_RUN_ORDER:-}" \
        fish "$ws/build-all.fish" --install-decide "$@" 2>"$ws/decide.err")
    FIXTURE_RC=$?
    set -e
}

assert_no_u() {
    grep -q -- 'pacman -U' "$ws/pacman.log" 2>/dev/null &&
        fail "$1: the decide seam must never touch pacman -U: $(cat "$ws/pacman.log")"
    checks=$((checks + 1))
}

# Installed state for the drift cases: old provider surface + an INSTALLED
# consumer (the closure member that would break). Each case re-sets these
# explicitly — inline VAR=… assignments leak into a bash function's shell.
GSA_FAKE_QI_LIBS='Name : libs-git
Version : 1.0.0-1
Provides : libgreet.so=1-64'
GSA_FAKE_QI_APP='Name : app-git
Version : 1.0.0-1
Provides : libapp.so=1-64'
GSA_FAKE_APP_INSTALLED=1

# ─── A. provide-diff + open closure → refusal rows, rc 1 ───────────────────
gsa_db_reset
gsa_provider
gsa_consumer
g_arch=$(gsa_archive libs-git 'libgreet.so=2-64')
gsa_decide force "$g_arch"
assert_decisions 'A: §E.2 refusal rows' 1 <<'EOF'
libs-git refuse abi-soname
libs-git refuse abi-consumer
EOF
seam_row_has A "libgreet.so 1-64 2-64" # the move, named in the row detail
seam_row_has A ' app-git'
checks=$((checks + 3))

# Checked mode refuses the same plan (the gate sits before the force branch,
# so neither mode routes around it).
gsa_decide checked "$g_arch"
assert_decisions 'A2: checked mode §E.2 rows' 1 <<'EOF'
libs-git refuse abi-soname
libs-git refuse abi-consumer
EOF
checks=$((checks + 1))

# ─── B. closure complete: the consumer rides in the transaction ────────────
# FISH-DRIVEN meaning (DEVIATION 2): the covered consumer's archive rides
# the same transaction → the fish gate plans CLEAN. The engine refuses the
# drifting surface per se and suppresses only the consumer row; its rows are
# pinned exactly as emitted.
: >"$ws/pacman.log"
decide force "$libs_arch" "$app_arch"
((FIXTURE_RC == 0)) ||
    fail "B: a complete closure must plan cleanly (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
grep -Fq 'refuse' <<<"$FIXTURE_OUTPUT" &&
    fail "B: no refusal rows expected over a covered closure: $FIXTURE_OUTPUT"
assert_no_u B
gsa_db_reset
gsa_provider
gsa_consumer
g_arch=$(gsa_archive libs-git 'libgreet.so=2-64')
g_app_arch=$(gsa_archive app-git 'libapp.so=1-64')
gsa_decide force "$g_arch" "$g_app_arch"
assert_decisions 'B: §E.2 rows over the covered closure (DEVIATION 2)' 1 <<'EOF'
libs-git refuse abi-soname
app-git install ok
EOF
checks=$((checks + 3))

# ─── C. consumer not installed — nothing to protect ────────────────────────
# FISH-DRIVEN meaning (DEVIATION 2): an uninstalled consumer cannot break →
# the fish gate plans clean; the engine's unconditional abi-soname refusal
# is pinned as emitted.
GSA_FAKE_APP_INSTALLED=0
GSA_FAKE_QI_APP=''
: >"$ws/pacman.log"
decide force "$libs_arch"
((FIXTURE_RC == 0)) ||
    fail "C: an uninstalled consumer must not gate (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
grep -Fq 'refuse' <<<"$FIXTURE_OUTPUT" &&
    fail "C: no refusal rows expected: $FIXTURE_OUTPUT"
assert_no_u C
gsa_db_reset
gsa_provider
g_arch=$(gsa_archive libs-git 'libgreet.so=2-64')
gsa_decide force "$g_arch"
assert_decisions 'C: §E.2 rows with the consumer absent (DEVIATION 2)' 1 <<'EOF'
libs-git refuse abi-soname
EOF
checks=$((checks + 3))

# ─── D. no provide diff → clean plan ───────────────────────────────────────
GSA_FAKE_APP_INSTALLED=1
GSA_FAKE_QI_APP='Name : app-git
Version : 1.0.0-1
Provides : libapp.so=1-64'
gsa_db_reset
gsa_provider 2-64
gsa_consumer
g_arch=$(gsa_archive libs-git 'libgreet.so=2-64')
gsa_decide force "$g_arch"
assert_decisions 'D: §E.2 rows over an unchanged surface' 0 <<'EOF'
libs-git install ok
EOF
checks=$((checks + 1))

# ─── E. disappearing provide → refusal with the '-' built side ─────────────
gsa_db_reset
gsa_provider
gsa_consumer
g_arch=$(gsa_archive libs-git 'libother.so=1-64')
gsa_decide force "$g_arch"
assert_decisions 'E: §E.2 refusal rows over a disappearing provide' 1 <<'EOF'
libs-git refuse abi-soname
libs-git refuse abi-consumer
EOF
seam_row_has E 'libgreet.so 1-64 -' # the disappearing side renders '-'
checks=$((checks + 2))

# ─── F. fresh install — the pkgname is not installed at all ────────────────
gsa_db_reset
g_arch=$(gsa_archive libs-git 'libgreet.so=2-64')
gsa_decide force "$g_arch"
assert_decisions 'F: §E.2 rows over a fresh install' 0 <<'EOF'
libs-git install ok
EOF
checks=$((checks + 1))

# ─── G. the force branch does not bypass the gate ──────────────────────────
# The REAL force-mode install executor (`gsa -Uf`, §B.6) must render the
# same refusal into the run record and abort before any pacman -U: the
# `install-refused …` outcome rows (§H.3) name the move and the uncovered
# consumer — the rendering is the record, never prose. The old package-log
# renderings (pre-P2 :416) re-pin here record-derived.
gsa_db_reset
gsa_provider
gsa_consumer
g_arch=$(gsa_archive libs-git 'libgreet.so=2-64')
gsa_install "$g_arch"
assert_refused_install 'G'
record_row_has G "install-refused abi-soname $g_arch libs-git libgreet.so 1-64 2-64"
record_row_has G "install-refused abi-consumer $g_arch app-git"
checks=$((checks + 3))

# ─── H. a spaced archive path survives into the refusal rows (R-F22) ──────
# The refusal rows carry the archive path too; the row must deliver it to
# the seam/consumer intact (the old space-joined row truncated at the first
# space and the rendering named a nonexistent archive).
(
    set -euo pipefail
    mkdir -p "$ws/spaced dir"
    gsa_db_reset
    gsa_provider
    gsa_consumer
    g_arch=$(gsa_archive libs-git 'libgreet.so=2-64')
    cp "$g_arch" "$ws/spaced dir/gsa libs-git-1.0.0-1-x86_64.pkg.tar.zst"
    gsa_decide force "$ws/spaced dir/gsa libs-git-1.0.0-1-x86_64.pkg.tar.zst"
    assert_decisions 'H: §E.2 refusal rows over a spaced path' 1 <<'EOF'
libs-git refuse abi-soname
libs-git refuse abi-consumer
EOF
    seam_row_has H "$ws/spaced dir/gsa libs-git-1.0.0-1-x86_64.pkg.tar.zst libs-git libgreet.so 1-64 2-64"
)
checks=$((checks + 2))

# ─── I. Stock→house swap: drifted counterpart surface → the same refusals ──
# The run #31 blind spot: nothing is installed for the ARCHIVE's pkgname
# (libs-git) — the old gate read that as a fresh install and skipped — but
# the stock counterpart (`libs`, stock_name) IS installed and its soname
# surface MOVES (`libgreet.so=1-64` → the build's `=2-64`), with the
# consumer closure open. The rows must be the same-pkgname shape (the
# subject stays the ARCHIVE's pkgbase; only the installed side comes from
# the counterpart's record), and the refusal must abort before any
# MUTATING invocation (the seam's fail-stubs make any spawn loud).
(
    set -euo pipefail
    gsa_db_reset
    gsa_stock
    gsa_consumer
    g_arch=$(gsa_archive libs-git 'libgreet.so=2-64')
    gsa_decide force "$g_arch"
    assert_decisions 'I: §E.2 swap refusal rows' 1 <<'EOF'
libs-git refuse abi-soname
libs-git refuse abi-consumer
EOF
    seam_row_has I 'libgreet.so 1-64 2-64' # the installed side from the counterpart
)
checks=$((checks + 2))

# ─── J. Stock→house swap with an IDENTICAL soname surface → clean plan ─────
# Same swap shape as I (nothing installed for libs-git, `libs` installed,
# consumer closure open) but the counterpart's surface matches the archive's
# exactly: a drop-in swap must plan cleanly — only a surface that MOVES
# strands consumers.
(
    set -euo pipefail
    gsa_db_reset
    gsa_stock 2-64
    gsa_consumer
    g_arch=$(gsa_archive libs-git 'libgreet.so=2-64')
    gsa_decide force "$g_arch"
    assert_decisions 'J: §E.2 rows over a drop-in swap' 0 <<'EOF'
libs-git install ok
EOF
)
checks=$((checks + 1))

# ─── K. in-run repair coverage: consumer scheduled after the provider ─────
# FISH-DRIVEN (DEVIATION 1): the -i contract rebuilds the consumer against
# the moved surface later in the SAME run (its install is what repairs the
# move), so a consumer in the exported run order strictly after the provider
# is COVERED: the fish plan is clean and carries the non-refusal `repair`
# row the executor turns into the forced-rebuild marker. This is the run #48
# wall. The seam cannot express that coverage (later_installs fixed empty,
# crates/gsa-cli/src/install.rs run_install_decide) and §E.3 has no repair
# decision (§8.1), so the fish row-set check compares the fish seam's rows
# field-wise (tabs normalized — the retired codec's byte framing is gone).
(
    set -euo pipefail
    make_archive "$ws" libs-git 'libgreet.so=2-64'
    GSA_FAKE_QI_LIBS='Name : libs-git
Version : 1.0.0-1
Provides : libgreet.so=1-64'
    GSA_FAKE_QI_APP='Name : app-git
Version : 1.0.0-1
Provides : libapp.so=1-64'
    GSA_FAKE_APP_INSTALLED=1
    _GSA_RUN_ORDER='libs-git app-git'
    : >"$ws/pacman.log"
    decide force "$libs_arch"
    ((FIXTURE_RC == 0)) ||
        fail "K: a consumer scheduled after the provider must be repaired in-run (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    k_expected="repair $libs_arch app-git libs-git
install $libs_arch"
    [[ $(tr '\t' ' ' <<<"$FIXTURE_OUTPUT") == "$k_expected" ]] ||
        fail "K: wrong repair plan rows (want repair+install rows).
want:
$k_expected
got:
$(tr '\t' ' ' <<<"$FIXTURE_OUTPUT")"
    assert_no_u K
    # The engine seam's ACTUAL rows for this state are pinned as emitted
    # (DEVIATION 1): with the consumer uncovered at the seam, the refusal
    # rows are what it produces.
    gsa_db_reset
    gsa_provider
    gsa_consumer
    g_arch=$(gsa_archive libs-git 'libgreet.so=2-64')
    gsa_decide force "$g_arch"
    assert_decisions 'K: §E.2 rows for the in-run-repair state (gap G1)' 1 <<'EOF'
libs-git refuse abi-soname
libs-git refuse abi-consumer
EOF
)
checks=$((checks + 3))

# ─── L. the consumer scheduled BEFORE the provider → refusals ─────────────
# FISH-DRIVEN order-sensitivity (DEVIATION 1): a consumer ordered before
# the provider is never repaired later. The §E.2 rows re-pin on the engine
# (the seam is order-blind — its rows for this state are the uncovered-
# consumer refusals, as pinned at A/K).
(
    set -euo pipefail
    _GSA_RUN_ORDER='app-git libs-git'
    : >"$ws/pacman.log"
    decide force "$libs_arch"
    ((FIXTURE_RC == 1)) ||
        fail "L: a consumer ordered before the provider is never repaired later (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    grep -Fq 'refuse' <<<"$FIXTURE_OUTPUT" ||
        fail "L: the usual refusals expected: $FIXTURE_OUTPUT"
    assert_no_u L
    gsa_db_reset
    gsa_provider
    gsa_consumer
    g_arch=$(gsa_archive libs-git 'libgreet.so=2-64')
    gsa_decide force "$g_arch"
    assert_decisions 'L: §E.2 refusal rows (consumer ordered before)' 1 <<'EOF'
libs-git refuse abi-soname
libs-git refuse abi-consumer
EOF
)
checks=$((checks + 3))

# ─── M. the consumer absent from the run order → refusals ─────────────────
# FISH-DRIVEN order-sensitivity (DEVIATION 1), as L.
(
    set -euo pipefail
    _GSA_RUN_ORDER='libs-git other-git'
    : >"$ws/pacman.log"
    decide force "$libs_arch"
    ((FIXTURE_RC == 1)) ||
        fail "M: a consumer the run never rebuilds must refuse (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    grep -Fq 'refuse' <<<"$FIXTURE_OUTPUT" ||
        fail "M: the usual refusals expected: $FIXTURE_OUTPUT"
    assert_no_u M
    gsa_db_reset
    gsa_provider
    gsa_consumer
    g_arch=$(gsa_archive libs-git 'libgreet.so=2-64')
    gsa_decide force "$g_arch"
    assert_decisions 'M: §E.2 refusal rows (consumer absent from the run)' 1 <<'EOF'
libs-git refuse abi-soname
libs-git refuse abi-consumer
EOF
)
checks=$((checks + 3))

# ─── N. the real -i executor: marker written before the move, consumed by
#        the consumer's own install ─────────────────────────────────────────
# FISH-DRIVEN (DEVIATION 1): the repair-marker cycle has no engine surface
# yet (the seam's repair coverage is gap G1).
(
    set -euo pipefail
    make_archive "$ws" libs-git 'libgreet.so=2-64'
    make_archive "$ws" app-git 'libapp.so=1-64'
    GSA_FAKE_QI_LIBS='Name : libs-git
Version : 1.0.0-1
Provides : libgreet.so=1-64'
    GSA_FAKE_QI_APP='Name : app-git
Version : 1.0.0-1
Provides : libapp.so=1-64'
    GSA_FAKE_APP_INSTALLED=1
    stub_sudo "$ws"
    stub_makepkg "$ws"
    # A missing GCC build-identity stamp makes the toolchain-drift clean
    # delete every cached archive before the build (the drift feature's own
    # contract) — stamp the CURRENT toolchain identity so the workspace
    # looks like a healthy build and this case stays about the repair cycle.
    mkdir -p "$ws/state/toolchains"
    gccline=$(LC_ALL=C gcc --version 2>/dev/null | head -1)
    [[ -n $gccline ]] || gccline='gcc unavailable'
    printf '%s\n%s\n' "$ws/packages/libs-git" "$gccline" >"$ws/state/toolchains/libs-git"
    printf '%s\n%s\n' "$ws/packages/app-git" "$gccline" >"$ws/state/toolchains/app-git"
    : >"$ws/pacman.log"
    : >"$ws/marker.snapshot"
    run_builder env \
        PATH="$ws/bin:$PATH" \
        GSA_STATE_DIR="$ws/state" \
        _IGNOREPKG_CONF="$ws/pacman.conf" \
        GSA_FAKE_PACMAN_LOG="$ws/pacman.log" \
        GSA_FAKE_QI_LIBS="$GSA_FAKE_QI_LIBS" \
        GSA_FAKE_QI_APP="$GSA_FAKE_QI_APP" \
        GSA_FAKE_APP_INSTALLED=1 \
        GSA_FAKE_ACCEPT_U=1 \
        GSA_FAKE_MARKER_SNAPSHOT="$ws/marker.snapshot" \
        GSA_CPU_THREADS=8 GSA_MEMORY_GIB=16 \
        fish "$ws/build-all.fish" --allow-broken-rustc --no-deps --no-sync -i libs-git app-git
    ((FIXTURE_RC == 0)) || fail "N: the in-run repair run must succeed: $FIXTURE_OUTPUT"
    n_log="$ws/state/logs/libs-git.log"
    [[ -f $n_log ]] || fail "N: no provider package log was written: $FIXTURE_OUTPUT"
    grep -Fq 'is scheduled for rebuild later in this run' "$n_log" ||
        fail "N: the repair note must render into the provider's log: $(cat "$n_log")"
    snap=$(cat "$ws/marker.snapshot")
    [[ $(grep -c '^U:' "$ws/marker.snapshot") -ge 2 ]] ||
        fail "N: expected at least two transactions (provider, then consumer): $snap"
    head -1 "$ws/marker.snapshot" | grep -Fq 'app-git' ||
        fail "N: the repair marker must be recorded BEFORE the provider's transaction lands: $snap"
    [[ ! -e "$ws/state/abi-repair/app-git" ]] ||
        fail "N: the consumer's install must consume its repair marker: $(ls "$ws/state/abi-repair")"
)
checks=$((checks + 4))

# ─── O. stock-side exact pinner: named refusal rows, before pacman ──────────
# The run #49 wall (stock wlroots0.20 pinning `libdisplay-info.so=3-64`):
# the pinner is OUT-OF-TREE and pins the moving provide exactly, and the
# workspace closure here is EMPTY (app-git not installed) — the pre-fix gate
# planned a clean install (`install` row, rc 0) that pacman would have
# refused in raw noise. The gate must read the local DB's reverse deps and
# refuse with rows naming the pinner + depstring. The executor half pins the
# rendering through the real force-mode install run (`gsa -Uf`).
(
    set -euo pipefail
    gsa_db_reset
    gsa_provider
    gsa_db stockpin 9.9-1 '' 'libgreet.so=1-64'
    g_arch=$(gsa_archive libs-git 'libgreet.so=2-64')
    gsa_decide force "$g_arch"
    assert_decisions 'O: §E.2 stock-pinner refusal rows (additive key, §L.2)' 1 <<'EOF'
libs-git refuse abi-soname
libs-git refuse abi-stock-pinner
EOF
    seam_row_has O 'stockpin libgreet.so=1-64' # the pinner and its exact depstring
    gsa_install "$g_arch"
    assert_refused_install 'O-executor'
    record_row_has O-executor "install-refused abi-stock-pinner $g_arch stockpin libgreet.so=1-64"
)
checks=$((checks + 3))

# ─── P. bare-link stock pinner named; a workspace pin stays the old class ───
# stockpin2 bare-links the moving provide (`Depends On : libgreet.so`) and
# must be named; app-git — a WORKSPACE recipe output — carries the same
# moving pin in the local DB but belongs to the surface-consumer logic (link
# truth → `refuse abi-consumer`), never to the stock-pinner row. The split
# is FISH-DRIVEN (DEVIATION 3: the engine names app-git as a stock-side
# pinner too — its rows are pinned as emitted, 4 rows).
(
    set -euo pipefail
    GSA_FAKE_QI_LIBS='Name : libs-git
Version : 1.0.0-1
Provides : libgreet.so=1-64'
    GSA_FAKE_QI_APP='Name : app-git
Version : 1.0.0-1
Provides : libapp.so=1-64'
    GSA_FAKE_APP_INSTALLED=1
    GSA_FAKE_QI_ALL='Name : app-git
Version : 1.0.0-1
Depends On : libgreet.so=1-64

Name : stockpin2
Version : 9.9-1
Depends On : libgreet.so'
    _GSA_RUN_ORDER=''
    : >"$ws/pacman.log"
    decide force "$libs_arch"
    ((FIXTURE_RC == 1)) ||
        fail "P: a bare-link stock pinner must refuse (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    p_rows=$(tr '\t' ' ' <<<"$FIXTURE_OUTPUT")
    grep -Fq "refuse abi-consumer $libs_arch app-git" <<<"$p_rows" ||
        fail "P: the workspace pin must stay the abi-consumer class: $p_rows"
    grep -Fq "refuse abi-stock-pinner $libs_arch stockpin2 libgreet.so" <<<"$p_rows" ||
        fail "P: the bare-link stock pinner must be named: $p_rows"
    if grep 'refuse abi-stock-pinner' <<<"$p_rows" | grep -Fq ' app-git'; then
        fail "P: a workspace output must never be named as a stock-side pinner: $p_rows"
    fi
    assert_no_u P
    # The engine rows for this state are pinned as emitted (DEVIATION 3):
    # the stock_pinner scan has no workspace filter, so app-git appears as
    # an abi-stock-pinner row alongside its abi-consumer row.
    gsa_db_reset
    gsa_provider
    gsa_consumer 'libgreet.so=1-64'
    gsa_db stockpin2 9.9-1 '' 'libgreet.so'
    g_arch=$(gsa_archive libs-git 'libgreet.so=2-64')
    gsa_decide force "$g_arch"
    assert_decisions 'P: §E.2 rows for the bare-link/split case (DEVIATION 3)' 1 <<'EOF'
libs-git refuse abi-soname
libs-git refuse abi-consumer
libs-git refuse abi-stock-pinner
libs-git refuse abi-stock-pinner
EOF
)
checks=$((checks + 4))

# ─── Q. a stock-side pinner whose OWN archive rides the transaction ────────
# The pinner's own archive installs in the SAME pacman -U: the old pin dies
# with the old package and pacman re-checks the new record's depends against
# the new provides — nothing to protect (FISH-DRIVEN clean-plan meaning,
# DEVIATION 2); the engine suppresses the pinner row (its `stockpin install
# ok` row) but refuses the drift per se — pinned as emitted.
(
    set -euo pipefail
    mkdir -p "$ws/packages/stockpin"
    make_archive "$ws" stockpin 'libstock.so=1-64'
    stock_arch="$ws/packages/stockpin/stockpin-1.0.0-1-x86_64.pkg.tar.zst"
    GSA_FAKE_QI_LIBS='Name : libs-git
Version : 1.0.0-1
Provides : libgreet.so=1-64'
    GSA_FAKE_QI_APP=''
    GSA_FAKE_APP_INSTALLED=0
    GSA_FAKE_QI_ALL='Name : stockpin
Version : 9.9-1
Depends On : libgreet.so=1-64'
    _GSA_RUN_ORDER=''
    : >"$ws/pacman.log"
    decide force "$libs_arch" "$stock_arch"
    ((FIXTURE_RC == 0)) ||
        fail "Q: a pinner in the transaction must be covered (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    grep -Fq 'refuse' <<<"$FIXTURE_OUTPUT" &&
        fail "Q: no refusal rows expected: $FIXTURE_OUTPUT"
    assert_no_u Q
    gsa_db_reset
    gsa_provider
    gsa_db stockpin 9.9-1 '' 'libgreet.so=1-64'
    g_arch=$(gsa_archive libs-git 'libgreet.so=2-64')
    g_stock_arch=$(gsa_archive stockpin 'libstock.so=1-64')
    gsa_decide force "$g_arch" "$g_stock_arch"
    assert_decisions 'Q: §E.2 rows for a pinner riding the transaction (DEVIATION 2)' 1 <<'EOF'
libs-git refuse abi-soname
stockpin install ok
EOF
)
checks=$((checks + 3))

# ─── seam usage contract (§E.5 rc 2): a bad mode prints no rows ────────────
gsa_db_reset
gsa_provider
g_arch=$(gsa_archive libs-git 'libgreet.so=2-64')
gsa_decide nonsense "$g_arch"
assert_decisions 'usage: §E.5 rc 2' 2 </dev/null
checks=$((checks + 1))

printf 'abi-drift-install fixture: PASS (%d checks)\n' "$checks"
