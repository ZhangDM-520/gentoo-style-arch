#!/usr/bin/env bash
set -euo pipefail

# ABI-drift guard layer 3 — the install-time fatal provide-diff refusal
# (build-all.fish abi_provide_refusals, an install-plan step beside
# pgo_payload_refusals, BEFORE the force branch). Through the hidden
# `--install-decide <checked|force>` seam — no pacman transaction, no sudo,
# no flock, no makepkg — this pins:
#
#   A. a bare soname provide that MOVES against the installed database
#      (libgreet.so=1-64 → libgreet.so=2-64, same pkgname) while the
#      installed consumer closure is NOT in the transaction → silent
#      `refuse abi-soname` + `refuse abi-consumer` rows, rc 1 (both modes);
#   B. closure complete: the consumer's archive rides in the same
#      transaction → rc 0, plain `install` rows;
#   C. nothing to protect: the consumer is not installed → rc 0;
#   D. no provide diff (same soname versions) → rc 0;
#   E. a DISAPPEARING provide (built archive drops the soname entirely) →
#      `refuse abi-soname … <installed-ver> -` + consumer rows, rc 1;
#   F. fresh install (the pkgname is not installed at all) → rc 0: nothing
#      installed can lose a provide;
#   G. the force branch does NOT bypass the gate: the REAL -i executor
#      renders the same refusal and aborts before pacman -U.
#   H. a spaced archive path survives the codec round trip (R-F22).
#   I. Stock→house swap (the run #31 blind spot): the archive's pkgname is
#      NOT installed but its stock counterpart (abi_stock_name) IS, with a
#      drifted soname surface and an uncovered consumer closure → the SAME
#      `refuse abi-soname` + `refuse abi-consumer` rows (pkgname field stays
#      the archive's pkgname; the installed side comes from the counterpart),
#      rc 1, and zero mutating invocations (no pacman -U, no sudo — the
#      decision half's only pacman traffic is read-only -Qi/-Q probes).
#   J. the swap with an IDENTICAL soname surface is a clean pass even with
#      the consumer closure open — only the surface MOVING strands consumers.
#      (The double-fresh shape — neither the pkgname nor the stock
#      counterpart installed — is case F: one more read-only probe, same
#      clean plan.)
#   K. in-run repair coverage (2026-10-07, run #48 wall): the surface
#      consumer scheduled strictly AFTER the provider in the exported run
#      order (_GSA_RUN_ORDER — run_lanes' topological selection) is rebuilt
#      and reinstalled by THIS run, so the move lands with a repair: clean
#      plan carrying the non-refusal row
#      `repair <archive> <consumer> <provider-id>`, no refusal rows;
#   L. the consumer scheduled BEFORE the provider in the run order → the
#      usual refusals (nothing later repairs it);
#   M. the consumer absent from the run order → the usual refusals (the run
#      never rebuilds it);
#   N. the REAL -i executor cycle: a run whose selection orders the consumer
#      after the provider plans `repair`, records the forced-rebuild marker
#      under $GSA_STATE_DIR/abi-repair/ BEFORE pacman -U (the stub snapshots
#      the marker dir at every transaction), renders the note into the
#      package log, and consumes the marker when the consumer's own install
#      lands.
#   O. STOCK-SIDE pinner (2026-10-07, run #49 wall #2): an OUT-OF-TREE
#      installed package (no workspace recipe) whose declared Depends pins
#      the moving provide EXACTLY (`libgreet.so=1-64`) while the workspace
#      closure is empty. The pre-fix gate planned a CLEAN install — pacman
#      would have refused it in raw noise. The gate must consult the LOCAL
#      DB's reverse deps (the `pacman -Qi --` full-dump seam,
#      abi_local_depend_rows) and refuse with rows naming the pinner and the
#      exact depstring: `refuse abi-stock-pinner <archive> <pinner> <dep>`.
#      The second half renders that refusal through the REAL -i executor
#      (case G's shape) so the row is a real message, never an
#      `unrecognized install-plan refusal`;
#   P. the bare-link shape and the split: a stock pinner with `Depends On :
#      libgreet.so` (bare) is named too — a bare linker of a moved soname
#      breaks at runtime exactly like a pin breaks pacman — while a
#      WORKSPACE recipe output carrying the same moving pin in the local DB
#      stays the existing class (`refuse abi-consumer`, link truth) and is
#      never named as a stock-side pinner;
#   Q. a stock-side pinner whose OWN archive rides the transaction is
#      covered: pacman re-checks its new depends against the new provides in
#      the same transaction → clean plan.
#
# The pacman stub is read-only (-Qi/-Q probes plus the `pacman -Qi --`
# full-dump the stock-pinner query reads, fabricated from GSA_FAKE_QI_ALL);
# every case asserts no `pacman -U` ever ran. Scratch workspaces under
# $TMPDIR only.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/tests/lib/fixture-lib.bash"
source "$root/tests/lib/rr-v2.bash"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-abi-drift-install.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    printf 'abi-drift-install fixture: %s\n' "$1" >&2
    exit 1
}

# ─── §E.2 decision rows: the R-5 re-pin (docs/gsa-fixture-migration.md §6) ───
# The tab plan-row codec (planrow) is retired with the tab framing — it has no
# v2 form. The row MEANINGS re-pin through the §E.2 parser
# (tests/lib/rr-v2.bash rr2_decisions) as `(pkgbase, decision, reason-key)`
# triples in plan order — detail after the reason key stripped (§7) — against
# the NATIVE engine's hidden `--install-decide` seam
# (docs/gsa-contract.md §D.1: decision rows on stdout, no pacman/sudo/flock/
# makepkg, rc 0 plan / 1 refusal / 2 bad usage). The fish seam runs below keep
# pinning the fish-era rc, row-absence and pacman-free behaviour; the §E.2
# assertions pin the gsa rows. The engine is built into the fixture tree
# (scratch only), the tests/scheduler-intensity.sh template.

cargo build --offline --quiet --target-dir "$tmp/cargo" -p gsa-cli \
    --manifest-path "$gsa_repo_root/Cargo.toml" ||
    fail "cannot build the gsa binary for the fixture"
gsa_bin="$tmp/cargo/debug/gsa"
[ -x "$gsa_bin" ] || fail "cargo did not produce $gsa_bin"
export GSA_TEST_ENGINE=gsa
export GSA_TEST_GSA_BIN="$gsa_bin"

# gsa-bin: the seam's only subprocess is `pacman-conf DBPath` (the local-DB
# root it reads natively — never the host's /var/lib/pacman). pacman/sudo are
# fail-stubs: nothing in a decision-only run may reach them (§D.1).
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
# seam's readelf stub above answers the same DT_NEEDED.
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
# whose DT_NEEDED is libgreet.so.1-64 (the stub readelf answers the same).
# The local-DB files entry carries the path minus its leading slash
# (crates/gsa-install/src/localdb.rs reads `/<files-entry>`).
consumer_elf="$tmp/consumer/lib-app-git.so"
mkdir -p "$tmp/consumer"
write_elf64_needed "$consumer_elf" 'libgreet.so.1-64'

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

# The installed-state builders (the same truth the GSA_FAKE_QI_* pacman stub
# answers above): the provider surface (old 1-64 by default, 2-64 when the
# case declares the new surface), the installed LINKED consumer (optionally
# with a moving pin in its Depends), and the stock counterpart `libs`.
gsa_provider() { gsa_db libs-git 1.0.0-1 "libgreet.so=${1:-1-64}"; }
gsa_consumer() { gsa_db app-git 1.0.0-1 'libapp.so=1-64' "${1:-}" "$consumer_elf"; }
gsa_stock() { gsa_db libs 1.0.0-1 "libgreet.so=${1:-1-64}"; }

# gsa_archive NAME [PROVIDE...] — one real .pkg.tar.zst with a COMPLETE
# .PKGINFO (the seam reads archive metadata natively and requires arch=; the
# make_archive shapes above stay the fish seam's inputs). Prints the path.
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

# decision_rows — the §E.2 decision rows of one engine capture (the seam
# prints rows alone), engine diagnostics dropped.
decision_rows() {
    awk '/^--- run record begin ---/ || /^Build run: / { exit } !/^gsa: / && NF { print }'
}

# assert_decisions LABEL RC — the §E.2 re-pin: $FIXTURE_OUTPUT's normalized
# (pkgbase, decision, reason-key) rows exactly as given on stdin, in plan
# order, plus the seam's rc contract (§E.5: 0 = no refuse row / 1 = >=1 refuse
# row / 2 = bad usage and no rows).
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

# The pacman stub: read-only probes only. Arguments arrive `pacman -Qi -- NAME`
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
    # path per installed member; the readelf stub answers its DT_NEEDED.
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

# The stub readelf: DT_NEEDED truth for the link filter. app-git LINKS the
# provider's soname (`libgreet.so.1-64`) — the fixture's installed consumer
# is exactly the class the gate protects; a consumer that never references
# the moving soname must not gate (pinned in tests/abi-batch-policy.sh G5).
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

# decide MODE [ARCHIVE...] — the seam. Stdout only (the rows) in
# FIXTURE_OUTPUT; stderr is kept apart so user fish-config noise can never
# disturb the row assertions (install-conflict-ask's convention).
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
: >"$ws/pacman.log"
decide force "$libs_arch"
((FIXTURE_RC == 1)) ||
    fail "A: a moving soname provide with an open closure must refuse (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
# §E.2 re-pin (R-5): the refusal rows' MEANING keeps as (libs-git, refuse,
# abi-soname) + (libs-git, refuse, abi-consumer) in plan order — the move and
# consumer detail after each reason key is not byte-pinned (§7).
gsa_db_reset
gsa_provider
gsa_consumer
g_arch=$(gsa_archive libs-git 'libgreet.so=2-64')
gsa_decide force "$g_arch"
assert_decisions 'A: §E.2 refusal rows' 1 <<'EOF'
libs-git refuse abi-soname
libs-git refuse abi-consumer
EOF
assert_no_u A
checks=$((checks + 2))

# Checked mode refuses the same plan (the gate sits before the force branch,
# so neither mode routes around it).
: >"$ws/pacman.log"
decide checked "$libs_arch"
((FIXTURE_RC == 1)) || fail "A2: checked mode must refuse too (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
gsa_decide checked "$g_arch"
assert_decisions 'A2: checked mode §E.2 rows' 1 <<'EOF'
libs-git refuse abi-soname
libs-git refuse abi-consumer
EOF
assert_no_u A2
checks=$((checks + 2))

# ─── B. closure complete: the consumer rides in the transaction ────────────
: >"$ws/pacman.log"
decide force "$libs_arch" "$app_arch"
((FIXTURE_RC == 0)) ||
    fail "B: a complete closure must plan cleanly (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
# §E.2 re-pin (R-5): the covered consumer's row keeps its meaning
# (`app-git install ok` — the closure rides the transaction, no
# `abi-consumer` refusal). GAP: the provider row is pinned as the engine
# actually emits it — gsa's provide gate refuses a moving surface even with
# the closure covered (`libs-git refuse abi-soname`), where fish planned
# `install` (recorded in the R-5 report; the fish rc pin above keeps the
# fish-era meaning alive).
gsa_db_reset
gsa_provider
gsa_consumer
g_arch=$(gsa_archive libs-git 'libgreet.so=2-64')
g_app_arch=$(gsa_archive app-git 'libapp.so=1-64')
gsa_decide force "$g_arch" "$g_app_arch"
assert_decisions 'B: §E.2 rows over the covered closure' 1 <<'EOF'
libs-git refuse abi-soname
app-git install ok
EOF
assert_no_u B
checks=$((checks + 3))

# ─── C. consumer not installed — nothing to protect ────────────────────────
GSA_FAKE_APP_INSTALLED=0
GSA_FAKE_QI_APP=''
: >"$ws/pacman.log"
decide force "$libs_arch"
((FIXTURE_RC == 0)) ||
    fail "C: an uninstalled consumer must not gate (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
grep -Fq 'refuse' <<<"$FIXTURE_OUTPUT" &&
    fail "C: no refusal rows expected: $FIXTURE_OUTPUT"
assert_no_u C
checks=$((checks + 2))

# ─── D. no provide diff → clean plan ───────────────────────────────────────
GSA_FAKE_APP_INSTALLED=1
GSA_FAKE_QI_APP='Name : app-git
Version : 1.0.0-1
Provides : libapp.so=1-64'
GSA_FAKE_QI_LIBS='Name : libs-git
Version : 1.0.0-1
Provides : libgreet.so=2-64'
: >"$ws/pacman.log"
decide force "$libs_arch"
((FIXTURE_RC == 0)) ||
    fail "D: an unchanged provide surface must plan cleanly (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
# §E.2 re-pin (R-5): an unchanged provide surface keeps its clean meaning
# (`libs-git install ok`).
gsa_db_reset
gsa_provider 2-64
gsa_consumer
g_arch=$(gsa_archive libs-git 'libgreet.so=2-64')
gsa_decide force "$g_arch"
assert_decisions 'D: §E.2 rows over an unchanged surface' 0 <<'EOF'
libs-git install ok
EOF
assert_no_u D
checks=$((checks + 2))

# ─── E. disappearing provide → refusal with the '-' built side ─────────────
make_archive "$ws" libs-git 'libother.so=1-64'
GSA_FAKE_QI_LIBS='Name : libs-git
Version : 1.0.0-1
Provides : libgreet.so=1-64'
: >"$ws/pacman.log"
decide force "$libs_arch"
((FIXTURE_RC == 1)) ||
    fail "E: a disappearing soname provide must refuse (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
# §E.2 re-pin (R-5): the disappearing provide keeps the same two row meanings
# (the built-side detail `1-64 -` is stripped with the reason detail, §7).
gsa_db_reset
gsa_provider
gsa_consumer
g_arch=$(gsa_archive libs-git 'libother.so=1-64')
gsa_decide force "$g_arch"
assert_decisions 'E: §E.2 refusal rows over a disappearing provide' 1 <<'EOF'
libs-git refuse abi-soname
libs-git refuse abi-consumer
EOF
assert_no_u E
checks=$((checks + 3))

# ─── F. fresh install — the pkgname is not installed at all ────────────────
GSA_FAKE_QI_LIBS=''
: >"$ws/pacman.log"
decide force "$libs_arch"
((FIXTURE_RC == 0)) ||
    fail "F: a fresh install cannot lose provides (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
grep -Fq 'refuse' <<<"$FIXTURE_OUTPUT" &&
    fail "F: no refusal rows expected: $FIXTURE_OUTPUT"
assert_no_u F
checks=$((checks + 2))

# ─── G. the force branch does not bypass the gate ──────────────────────────
# -fi/-ia plan in force mode; force bypasses only the same-version SKIP. Pin
# the RENDERING through the real executor: the refusal must abort the run
# before any pacman -U, naming the move and the uncovered consumer.
make_archive "$ws" libs-git 'libgreet.so=2-64'
GSA_FAKE_QI_LIBS='Name : libs-git
Version : 1.0.0-1
Provides : libgreet.so=1-64'
stub_sudo "$ws"
stub_makepkg "$ws"
# A missing GCC build-identity stamp makes the toolchain-drift clean delete
# every cached archive before the build (the drift feature's own contract) —
# which would silently destroy this case's pre-made bumped-provide archive.
# Stamp the CURRENT toolchain identity so the workspace looks like a healthy
# build and this case stays about the ABI gate, not toolchain drift.
mkdir -p "$ws/state/toolchains"
gccline=$(LC_ALL=C gcc --version 2>/dev/null | head -1)
[[ -n $gccline ]] || gccline='gcc unavailable'
printf '%s\n%s\n' "$ws/packages/libs-git" "$gccline" >"$ws/state/toolchains/libs-git"
: >"$ws/pacman.log"
run_builder env \
    PATH="$ws/bin:$PATH" \
    GSA_STATE_DIR="$ws/state" \
    _IGNOREPKG_CONF="$ws/pacman.conf" \
    GSA_FAKE_PACMAN_LOG="$ws/pacman.log" \
    GSA_FAKE_QI_LIBS="$GSA_FAKE_QI_LIBS" \
    GSA_FAKE_QI_APP="$GSA_FAKE_QI_APP" \
    GSA_FAKE_APP_INSTALLED=1 \
    GSA_CPU_THREADS=8 GSA_MEMORY_GIB=16 \
    fish "$ws/build-all.fish" --allow-broken-rustc --no-deps --no-sync -i libs-git
((FIXTURE_RC != 0)) || fail "G: the -i run must fail on the refused plan: $FIXTURE_OUTPUT"
# The -i lane renders its refusals into the package log (quiet sink — lanes
# never write to the terminal), so that transcript is the assertion surface.
g_log="$ws/state/logs/libs-git.log"
[[ -f $g_log ]] || fail "G: no package log was written: $FIXTURE_OUTPUT"
grep -Fq 'soname provide libgreet.so moves 1-64 -> 2-64' "$g_log" ||
    fail "G: the refusal must render the move: $(cat "$g_log")"
grep -Fq 'installed consumer app-git is not in this transaction' "$g_log" ||
    fail "G: the refusal must name the consumer: $(cat "$g_log")"
assert_no_u G
checks=$((checks + 3))

# ─── H. a spaced archive path survives the abi refusal rows (R-F22) ────────
# The refusal rows carry the archive path too; the tab-framed codec must
# deliver it to the seam/consumer intact (the old space-joined row truncated
# at the first space and the rendering named a nonexistent archive).
(
    mkdir -p "$ws/spaced dir"
    make_archive "$ws" libs-git 'libgreet.so=2-64'
    sp_arch="$ws/spaced dir/libs-git-1.0.0-1-x86_64.pkg.tar.zst"
    cp "$libs_arch" "$sp_arch"
    GSA_FAKE_QI_LIBS='Name : libs-git
Version : 1.0.0-1
Provides : libgreet.so=1-64'
    GSA_FAKE_QI_APP='Name : app-git
Version : 1.0.0-1
Provides : libapp.so=1-64'
    GSA_FAKE_APP_INSTALLED=1
    : >"$ws/pacman.log"
    decide force "$sp_arch"
    ((FIXTURE_RC == 1)) ||
        fail "H: a moving provide over a spaced path must refuse (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    # §E.2 re-pin (R-5): the refusal rows over a spaced archive path — the
    # path lives in the reason detail and is not byte-pinned (§7), the
    # decision rows are.
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
    assert_no_u H
    checks=$((checks + 2))
)

# ─── I. Stock→house swap: drifted counterpart surface → the same refusals ──
# The run #31 blind spot: nothing is installed for the ARCHIVE's pkgname
# (libs-git) — the old gate read that as a fresh install and skipped — but the
# stock counterpart (`libs`, abi_stock_name) IS installed and its soname
# surface MOVES (`libgreet.so=1-64` → the build's `=2-64`), with the
# consumer closure open. The rows must be the same-pkgname shape (the
# pkgname field stays the ARCHIVE's pkgname; only the installed side comes
# from the counterpart's record), and the refusal must abort before any
# MUTATING invocation. The decision half's only installed-database traffic is
# the read-only -Qi/-Q probes the gate cannot see the drift without — the
# "zero pacman/sudo" contract is zero transactions/escalations, pinned below
# by the log shapes. The sudo stub is an ORACLE (logs to a path derived from
# itself, so no env can silence it): any escalation at all must show up.
(
    set -euo pipefail
    cat >"$ws/bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -u
log=$(dirname "$0")/../sudo.log
printf 'sudo %s\n' "$*" >>"$log"
exit 99
EOF
    chmod +x "$ws/bin/sudo"
    make_archive "$ws" libs-git 'libgreet.so=2-64'
    GSA_FAKE_QI_LIBS=''
    GSA_FAKE_QI_STOCK='Name : libs
Version : 1.0.0-1
Provides : libgreet.so=1-64'
    GSA_FAKE_QI_APP='Name : app-git
Version : 1.0.0-1
Provides : libapp.so=1-64'
    GSA_FAKE_APP_INSTALLED=1
    : >"$ws/pacman.log"
    : >"$ws/sudo.log"
    decide force "$libs_arch"
    ((FIXTURE_RC == 1)) ||
        fail "I: a Stock→house swap moving the soname surface must refuse (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    # §E.2 re-pin (R-5): the swap refusal rows keep their meaning (the
    # subject stays the ARCHIVE's pkgbase; the installed side comes from the
    # stock counterpart's record).
    gsa_db_reset
    gsa_stock
    gsa_consumer
    g_arch=$(gsa_archive libs-git 'libgreet.so=2-64')
    gsa_decide force "$g_arch"
    assert_decisions 'I: §E.2 swap refusal rows' 1 <<'EOF'
libs-git refuse abi-soname
libs-git refuse abi-consumer
EOF
    if grep -Evq '^pacman -(Qi|Ql|Q) ' "$ws/pacman.log"; then
        fail "I: the refusal path must make only read-only pacman probes: $(cat "$ws/pacman.log")"
    fi
    assert_no_u I
    [[ ! -s "$ws/sudo.log" ]] ||
        fail "I: a refused plan must never escalate via sudo: $(cat "$ws/sudo.log")"
    checks=$((checks + 3))
)

# ─── J. Stock→house swap with an IDENTICAL soname surface → clean plan ─────
# Same swap shape as I (nothing installed for libs-git, `libs` installed,
# consumer closure open) but the counterpart's surface matches the archive's
# exactly: a drop-in swap must plan cleanly — only a surface that MOVES
# strands consumers.
(
    set -euo pipefail
    make_archive "$ws" libs-git 'libgreet.so=2-64'
    GSA_FAKE_QI_LIBS=''
    GSA_FAKE_QI_STOCK='Name : libs
Version : 1.0.0-1
Provides : libgreet.so=2-64'
    GSA_FAKE_QI_APP='Name : app-git
Version : 1.0.0-1
Provides : libapp.so=1-64'
    GSA_FAKE_APP_INSTALLED=1
    : >"$ws/pacman.log"
    : >"$ws/sudo.log"
    decide force "$libs_arch"
    ((FIXTURE_RC == 0)) ||
        fail "J: a drop-in swap (identical soname provides) must plan cleanly (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    # §E.2 re-pin (R-5): an identical counterpart surface keeps its clean
    # meaning (`libs-git install ok`).
    gsa_db_reset
    gsa_stock 2-64
    gsa_consumer
    g_arch=$(gsa_archive libs-git 'libgreet.so=2-64')
    gsa_decide force "$g_arch"
    assert_decisions 'J: §E.2 rows over a drop-in swap' 0 <<'EOF'
libs-git install ok
EOF
    grep -Fq 'refuse' <<<"$FIXTURE_OUTPUT" &&
        fail "J: no refusal rows expected: $FIXTURE_OUTPUT"
    if grep -Evq '^pacman -(Qi|Ql|Q) ' "$ws/pacman.log"; then
        fail "J: the decide seam made a non-probe pacman call: $(cat "$ws/pacman.log")"
    fi
    [[ ! -s "$ws/sudo.log" ]] ||
        fail "J: the decide seam must never escalate via sudo: $(cat "$ws/sudo.log")"
    checks=$((checks + 3))
)

# ─── K. in-run repair coverage: consumer scheduled after the provider ─────
# The -i contract rebuilds the consumer against the moved surface later in
# the SAME run (its install is what repairs the move), so a consumer in the
# exported run order strictly after the provider is COVERED: the plan is
# clean and carries the non-refusal `repair` row the executor turns into the
# forced-rebuild marker. This is the run #48 wall: niri-spicy-git WAS in the
# selection, ordered after libdisplay-info-git, and the gate refused anyway.
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
    # §E.2 re-pin (R-5, contract gap 1): the `repair <arch> …` row has NO §E.3
    # form, and the seam cannot express in-run repair coverage at all — §D.1's
    # shape takes only <checked|force> <archive…> and the engine's
    # DecisionContext.later_installs is fixed empty on that path
    # (crates/gsa-cli/src/install.rs run_install_decide). The engine's ACTUAL
    # rows for this state are pinned as observed: with the consumer uncovered
    # at the seam the refusal rows are what it emits. The repair-coverage
    # MEANING stays pinned on the fish side (case N's executor cycle, below),
    # and the divergence is recorded in the R-5 report.
    gsa_db_reset
    gsa_provider
    gsa_consumer
    g_arch=$(gsa_archive libs-git 'libgreet.so=2-64')
    gsa_decide force "$g_arch"
    assert_decisions 'K: §E.2 rows for the in-run-repair state (gap 1)' 1 <<'EOF'
libs-git refuse abi-soname
libs-git refuse abi-consumer
EOF
    assert_no_u K
)
checks=$((checks + 2))

# ─── L. the consumer scheduled BEFORE the provider → refusals ─────────────
(
    set -euo pipefail
    _GSA_RUN_ORDER='app-git libs-git'
    : >"$ws/pacman.log"
    decide force "$libs_arch"
    ((FIXTURE_RC == 1)) ||
        fail "L: a consumer ordered before the provider is never repaired later (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    # §E.2 re-pin (R-5): the refusal rows keep their meaning. The run-order
    # sensitivity (_GSA_RUN_ORDER) has no seam equivalent — the fish rc pin
    # above carries it; the gsa rows are the uncovered-consumer refusals.
    gsa_db_reset
    gsa_provider
    gsa_consumer
    g_arch=$(gsa_archive libs-git 'libgreet.so=2-64')
    gsa_decide force "$g_arch"
    assert_decisions 'L: §E.2 refusal rows (consumer ordered before)' 1 <<'EOF'
libs-git refuse abi-soname
libs-git refuse abi-consumer
EOF
    assert_no_u L
)
checks=$((checks + 2))

# ─── M. the consumer absent from the run order → refusals ─────────────────
(
    set -euo pipefail
    _GSA_RUN_ORDER='libs-git other-git'
    : >"$ws/pacman.log"
    decide force "$libs_arch"
    ((FIXTURE_RC == 1)) ||
        fail "M: a consumer the run never rebuilds must refuse (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    # §E.2 re-pin (R-5): as L — the rows keep their meaning; the run-order
    # absence is fish-side (_GSA_RUN_ORDER).
    gsa_db_reset
    gsa_provider
    gsa_consumer
    g_arch=$(gsa_archive libs-git 'libgreet.so=2-64')
    gsa_decide force "$g_arch"
    assert_decisions 'M: §E.2 refusal rows (consumer absent from the run)' 1 <<'EOF'
libs-git refuse abi-soname
libs-git refuse abi-consumer
EOF
    assert_no_u M
)
checks=$((checks + 2))

# ─── N. the real -i executor: marker written before the move, consumed by
#        the consumer's own install ─────────────────────────────────────────
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
    # Same toolchain-identity stamps as G: a missing stamp makes the
    # drift clean delete the pre-made archives before the build.
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
# rendering through the real -i path.
(
    set -euo pipefail
    make_archive "$ws" libs-git 'libgreet.so=2-64'
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
    decide force "$libs_arch"
    ((FIXTURE_RC == 1)) ||
        fail "O: a stock-side pinner of the moving provide must refuse (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    # §E.2 re-pin (R-5, contract gap 1): the stock-pinner refusal keeps its
    # meaning as (libs-git, refuse, abi-stock-pinner). `abi-stock-pinner` is
    # outside §E.3's reason-key list and is pinned as an ADDITIVE reason key
    # (§L.2 allows additive keys); the pinner name and depstring are reason
    # detail (§7, not byte-pinned).
    gsa_db_reset
    gsa_provider
    gsa_db stockpin 9.9-1 '' 'libgreet.so=1-64'
    g_arch=$(gsa_archive libs-git 'libgreet.so=2-64')
    gsa_decide force "$g_arch"
    assert_decisions 'O: §E.2 stock-pinner refusal rows (gap 1)' 1 <<'EOF'
libs-git refuse abi-soname
libs-git refuse abi-stock-pinner
EOF
    assert_no_u O
    stub_sudo "$ws"
    stub_makepkg "$ws"
    # Same toolchain-identity stamp as G/N: a missing stamp makes the drift
    # clean delete the pre-made bumped-provide archive before the build.
    mkdir -p "$ws/state/toolchains"
    gccline=$(LC_ALL=C gcc --version 2>/dev/null | head -1)
    [[ -n $gccline ]] || gccline='gcc unavailable'
    printf '%s\n%s\n' "$ws/packages/libs-git" "$gccline" >"$ws/state/toolchains/libs-git"
    : >"$ws/pacman.log"
    run_builder env \
        PATH="$ws/bin:$PATH" \
        GSA_STATE_DIR="$ws/state" \
        _IGNOREPKG_CONF="$ws/pacman.conf" \
        GSA_FAKE_PACMAN_LOG="$ws/pacman.log" \
        GSA_FAKE_QI_LIBS="$GSA_FAKE_QI_LIBS" \
        GSA_FAKE_QI_APP='' \
        GSA_FAKE_APP_INSTALLED=0 \
        GSA_FAKE_QI_ALL="$GSA_FAKE_QI_ALL" \
        GSA_CPU_THREADS=8 GSA_MEMORY_GIB=16 \
        fish "$ws/build-all.fish" --allow-broken-rustc --no-deps --no-sync -i libs-git
    ((FIXTURE_RC != 0)) || fail "O: the -i run must fail on the refused plan: $FIXTURE_OUTPUT"
    o_log="$ws/state/logs/libs-git.log"
    [[ -f $o_log ]] || fail "O: no package log was written: $FIXTURE_OUTPUT"
    grep -Fq 'installed stock-side package stockpin requires libgreet.so=1-64' "$o_log" ||
        fail "O: the refusal must name the pinner and its depstring: $(cat "$o_log")"
    assert_no_u O-executor
)
checks=$((checks + 4))

# ─── P. bare-link stock pinner named; a workspace pin stays the old class ───
# stockpin2 bare-links the moving provide (`Depends On : libgreet.so`) and
# must be named; app-git — a WORKSPACE recipe output — carries the same
# moving pin in the local DB but belongs to the surface-consumer logic (link
# truth → `refuse abi-consumer`), never to the stock-pinner row. The exact
# match fails if either half misbehaves (a missing row or an extra
# `refuse abi-stock-pinner … app-git …` row).
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
    # §E.2 re-pin (R-5): the bare-link pinner's `abi-stock-pinner` row is the
    # last (the §7-stripped detail carries which pinner). GAP: the engine ALSO
    # emits an `abi-stock-pinner` row naming the WORKSPACE output app-git (its
    # stock_pinners scan has no workspace filter), where fish keeps app-git in
    # the `abi-consumer` class only and never names it as a stock-side pinner
    # — pinned as emitted, recorded in the R-5 report.
    gsa_db_reset
    gsa_provider
    gsa_consumer 'libgreet.so=1-64'
    gsa_db stockpin2 9.9-1 '' 'libgreet.so'
    g_arch=$(gsa_archive libs-git 'libgreet.so=2-64')
    gsa_decide force "$g_arch"
    assert_decisions 'P: §E.2 rows for the bare-link/split case' 1 <<'EOF'
libs-git refuse abi-soname
libs-git refuse abi-consumer
libs-git refuse abi-stock-pinner
libs-git refuse abi-stock-pinner
EOF
    assert_no_u P
)
checks=$((checks + 2))

# ─── Q. a stock-side pinner riding the transaction is covered ──────────────
# The pinner's own archive installs in the SAME pacman -U: the old pin dies
# with the old package and pacman re-checks the new record's depends against
# the new provides — nothing to protect, clean plan.
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
    # §E.2 re-pin (R-5): the pinner's row keeps its meaning (`stockpin
    # install ok` — the pinner rides the transaction, no `abi-stock-pinner`
    # refusal). GAP: the provider row is pinned as the engine emits it
    # (`libs-git refuse abi-soname` — see B's note; fish planned `install`).
    gsa_db_reset
    gsa_provider
    gsa_db stockpin 9.9-1 '' 'libgreet.so=1-64'
    g_arch=$(gsa_archive libs-git 'libgreet.so=2-64')
    g_stock_arch=$(gsa_archive stockpin 'libstock.so=1-64')
    gsa_decide force "$g_arch" "$g_stock_arch"
    assert_decisions 'Q: §E.2 rows for a pinner riding the transaction' 1 <<'EOF'
libs-git refuse abi-soname
stockpin install ok
EOF
    assert_no_u Q
)
checks=$((checks + 3))

printf 'abi-drift-install fixture: PASS (%d checks)\n' "$checks"
