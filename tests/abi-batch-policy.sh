#!/usr/bin/env bash
set -euo pipefail

# Regression fixture for the 2026-09-25 LLVM-snapshot ABI-skew incident
# (docs/NOTE.md, 2026-09-25): the run's own `llvm-git` install landed a new
# LLVM C++ ABI mid-run and instantly broke the installed `rustc`
# (`librustc_driver` cannot resolve `llvm::cl::ParseCommandLineOptions…,
# version LLVM_24.0`). The preflight probe (check_rustc_sanity) had passed at
# run start and was never re-run, and recipes that compile Rust could be
# dispatched before rust-git in a coupled batch.
#
# Eight policy seams are pinned here, one section each (A–H). The fixture
# drives the NATIVE `gsa` engine through tests/lib/rr-v2.bash wherever the
# engine carries the machinery; the two fish-era sections whose machinery has
# no engine counterpart say so in their own headers (DEVIATION 2/4 below).
#
#   A. toolchain lint (`gsa -Ma`): a recipe whose PKGBUILD invokes cargo/rustc
#      must name rust-git in its topology record's edges field (rust-git
#      itself excepted); report-only (§E.4: an audit never refuses, exit 0).
#   B. ABI-batch policy on the engine (the pre-dispatch wave check,
#      crates/gsa-cli/src/build.rs `wave_check` + the gsa-abi wave planner):
#      an abi=must batch member omitted from a --leaf selection still RIDES
#      IN (wave `coupled-must` basis — the anchor can never build without its
#      member), and a same-pass member the topology cannot build refuses the
#      run BEFORE dispatch (`refuse abi-consumer-uncovered`, §E.2–E.3, §G.1
#      rc 3). Read-only surfaces keep rendering.
#   C. Dispatcher probe (FISH-DRIVEN, DEVIATION 2): with -i, a successful lane
#      for llvm-git re-runs check_rustc_sanity BEFORE anything else dispatches;
#      a failing probe with no remediation chain stops dispatch, drains
#      in-flight lanes, exits non-zero.
#   D. Repo policy: config/topology.conf declares mold-git's rust-git edge and
#      the llvm-git / rust-git abi=must batch tags, read through the engine's
#      `gsa -Qt` data channel (§B.3), and a bare-name selection orders the
#      anchor before its consumer (record `order` scalar, §H.2).
#   E. Non-ABI tags: app-cluster/version-sync-only records keep the ABI
#      severity result at `none` at the real-build gate (the -S run succeeds).
#   F. Grouping policy: the committed topology's group discipline
#      (docs/MEMORY.md §1 rule 21) — raw-record reads of
#      ${1:-$root/config/topology.conf}; engine-independent, unchanged from
#      the fish era.
#   G. ABI-drift gate at the §E.2 decision seam (`gsa --install-decide`):
#      a provider whose soname-provides set moves against the installed stock
#      package's provides refuses naming the drifted surface, and the refusal
#      rows name exactly the uncovered DIRECT surface consumers that LINK the
#      moving soname (the one-hop / link-truth boundary of the 2026-10-07
#      gate fault); covered consumers ride the transaction and are never
#      named. The seam is pacman-free end to end (rule 25(h)).
#   H. Gate COST at synthetic scale (probe-count bounds): the engine's
#      decision pass consults the installed DB exactly ONCE for a whole-pass
#      decision (one `pacman-conf DBPath` fork, never one per
#      (provider × member) visit) and touches no pacman/sudo/makepkg; the
#      decisions at scale name exactly the 240 linked members. The fish-era
#      per-name probe-count pins keep driving the fish gate (DEVIATION 4).
#
# Synthetic workspaces + PATH stubs only; nothing real is built or installed,
# and the fabricated pacman local DBs answer every installed-state question.
#
# ─── Flip notes (docs/gsa-fixture-migration.md row `tests/abi-batch-policy.sh`)
# argv map: `--audit` -> `gsa -Ma` (§B.7), `--topology` -> `gsa -Qt` (§B.3),
# `-i` -> `gsa -S` (§B.4), `-n` -> `--dry-run`, `-l` -> `gsa -Bl`/`-Sl`,
# `--no-deps` -> `--leaf` (§B.8). Refusal prose (the fish-era :232-236,
# :368-370, :842-844) retires as rendering (§L.3); its meanings re-pin as
# §E.2 `refuse` rows (`abi-soname` / `abi-consumer` /
# `abi-consumer-uncovered`), §H.2 `outcome`/`rc` scalars + outcome rows, and
# §G.1 rc 3. The two rr-format1 sites (E) re-pin through rr2_* (`format: 2`).
# DEVIATION 1 (inventory KEEP cell :242-244 "refusal-before-dispatch" —
# trigger flip, §E.2–E.3 target): the fish tag gate REFUSED a [abi=must
# anchor] --leaf selection whenever an installed abi=must member was omitted
# (no state required; "refuse, never silently expand"). The engine's
# coupled-batch term instead HEALS the omission — the member joins the plan
# as a wave addition with basis `coupled-must`, even under --leaf — and
# refuses only what the topology cannot build at all (`refuse
# abi-consumer-uncovered`, rc 3, every row `never-started`, nothing
# dispatched). B1/B2 re-pin both halves; the fish trigger (installed-member
# omission refusing with no state) has no engine surface and retires with
# this note. The wave mechanics themselves are tests/gsa-abi-v2.sh's subject;
# B pins this fixture's batch-policy meaning.
# DEVIATION 2 (inventory KEEP cell :356-361 "probe-stop-drain" — section C
# stays FISH-DRIVEN, the abi-postinstall-probe.sh pattern): the engine's
# rustc sanity probe (crates/gsa-recipe/src/toolchain.rs `rustc_sanity_probe`)
# has NO production caller in the run pipeline, and `--allow-broken-rustc` is
# a deferred spelling (parse-and-refuse rc 2), so the mid-run probe has no
# engine trigger and no stub can flip one. Section C keeps driving the fish
# builder this workspace carries, against its fish-era stubs and byte pins.
# DEVIATION 3 (inventory KEEP cells :850-852 / :872-941 — the G gate's
# fail-closed flip): the engine's provide gate refuses a MOVING surface even
# when the closure is covered or no consumer is installed, where the fish
# layer-2 selection gate planned clean — the same GAP
# tests/abi-drift-install.sh records at its case-B re-pin ("gsa's provide gate
# refuses a moving surface even with the closure covered"). The gate MEANINGS
# keep: the refusal names the drifted surface (`refuse abi-soname … <inst>
# <built>`) and exactly the uncovered linked consumers (`refuse abi-consumer
# … <consumer>`), covered consumers ride the transaction and are never named,
# and an uninstalled consumer never gates (no `abi-consumer` row). "Nothing
# is dispatched before it decides" keeps as the seam's own contract (§D.1:
# the seam runs no makepkg/sudo/pacman at all) plus the named rc §E.5 classes.
# DEVIATION 4 (inventory KEEP cell :1186-1245 "gate cost" — probe channel):
# the fish gate forked one `pacman -Q`/`-Qi` per (anchor × member) visit until
# its keyed helpers memoised it to one probe per unique name. The engine's
# gate parses the installed DB ONCE per decision pass (memoised by
# construction, in-process) and forks nothing per name, so the per-name probe
# counts have no engine channel. The bound re-pins engine-side as: exactly one
# `pacman-conf DBPath` consult per whole-pass decision (H4), zero
# pacman/sudo/makepkg invocations, and the scale decisions naming exactly the
# 240 linked members. The fish section H keeps its per-name pins against the
# fish gate (its keyed helpers live only in the fish builder).
# DEVIATION 5 (§H.2 known debt — format-2 scalars on plan records):
# `gsa -B --dry-run` (and `-U`) run records render `lanes: -` and extension
# scalars (`dry-run: yes`), which rr2_body rejects (strict integer budget
# scalars — tests/gsa-install-v2.sh records the same debt). Those sites
# extract their scalars inline (record_scalar below); every -B/-S run record
# in this fixture parses through rr2_*.
# DEVIATION 6 (inventory prose :495-499 — E's rendering pins): the
# 'same-pass candidates not in this selection: fcitx5-qt-git' note and the
# fish bug-grep 'test: Missing argument at index 3' retire as rendering
# (§6 prose class). Their meanings (a combined app-cluster/abi=should record
# never produces an empty ABI severity at the real-build gate) re-pin as the
# run record: rc 0, outcome success, every selected row succeeded.
# DEVIATION 7 (inventory KEEP cell :242-244's read-only half, B3): the fish
# pin "the read-only modes stay unaffected — the refusal gates real builds
# only" flips: the engine's wave gate is selection-level, so --dry-run on the
# same refusal state exits 3 (§G.1) while still rendering the full plan and
# record and building nothing; the listing (`-Bl`) stays rc 0. Both are
# pinned as such.
#
# Nothing here touches the real repository except D's read-only `gsa -Qt` of
# the committed topology; every workspace is synthetic under $TMPDIR, state
# roots are redirected (`GSA_STATE_DIR`), and pacman/pacman-conf/sudo stay
# stubs.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-abi-batch.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    printf 'abi-batch-policy fixture: %s\n' "$*" >&2
    exit 1
}

# Synthetic packages carry the 1.0.0-1-any metadata their stubs' archive names
# assume; the helper's add_package writes a one-line PKGBUILD, so that metadata
# rides in as extra-pkglines via gsa_meta_any. Kept for the fish sections.
add_meta_package() { # $1 = dir, $2 = id, $3 = extra PKGBUILD body (may be empty)
    local extra=$gsa_meta_any
    [[ -n ${3:-} ]] && extra+=$'\n'"$3"
    add_package "$1" "$2" "$extra"
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

# ─── Stub-knob vocabulary (§D.2: declared here in the change that adds them) ─
rr2_stub_knob GSA_FAKE_PACMAN_CONF_LOG "abi-batch pacman-conf stub: DBPath consult log (the H4 cost channel)"

# ─── Engine-side oracle stubs and derivation helpers (inline: §D.2 keeps
# oracles in the fixture that gives them meaning) ───────────────────────────

# write_real_makepkg DIR — the scenario makepkg: one BUILD marker per build
# plus one REAL archive (staged .PKGINFO tar) — the engine's install discovery
# and binpkg index read each archive's own .PKGINFO, so an empty file would
# register nothing and refuse `empty-list`.
write_real_makepkg() {
    cat >"$1/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
id=$(basename "$PWD")
printf 'BUILD %s\n' "$id" >>"${GSA_FAKE_MAKEPKG_LOG:?}"
stage="$PWD/.stage-$id"
mkdir -p "$stage"
{
    printf 'pkgbase = %s\n' "$id"
    printf 'pkgname = %s\n' "$id"
    printf 'pkgver = 1.0.0-1\n'
    printf 'arch = any\n'
} >"$stage/.PKGINFO"
tar --zstd -cf "$PWD/$id-1.0.0-1-any.pkg.tar.zst" -C "$stage" .PKGINFO
rm -rf "$stage"
exit 0
EOF
    chmod +x "$1/bin/makepkg"
}

# write_stub_pacman DIR — the transaction oracle: one argv line per call.
write_stub_pacman() {
    cat >"$1/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'pacman %s\n' "$*" >>"${GSA_FAKE_PACMAN_LOG:?}"
exit 0
EOF
    chmod +x "$1/bin/pacman"
}

# write_stub_sudo DIR — the sudo passthrough stub (the engine may only ever
# run `sudo -n <cmd>`, §K.3); the log is what (never) escalated.
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
# fixture's fabricated DB root (never the host's) and logs every consult —
# the installed-DB consult count is H4's cost channel.
write_stub_pacman_conf() {
    cat >"$1/bin/pacman-conf" <<EOF
#!/usr/bin/env bash
set -u
printf 'pacman-conf %s\n' "\$*" >>"\${GSA_FAKE_PACMAN_CONF_LOG:?}"
[ "\${1:-}" = DBPath ] && printf '%s\n' "$2"
exit 0
EOF
    chmod +x "$1/bin/pacman-conf"
}

# engine_ws WS DB — one workspace with every stub wired and the fabricated DB
# pointed at; exports the log knobs the stubs read.
engine_ws() {
    local ws=$1 db=$2
    write_real_makepkg "$ws"
    write_stub_pacman "$ws"
    write_stub_sudo "$ws"
    write_stub_pacman_conf "$ws" "$db"
    mkdir -p "$db/local"
    export PATH="$ws/bin:$PATH"
    export GSA_STATE_DIR="$ws/state"
    export GSA_FAKE_MAKEPKG_LOG="$ws/makepkg.log"
    export GSA_FAKE_PACMAN_LOG="$ws/pacman.log"
    export GSA_FAKE_SUDO_LOG="$ws/sudo.log"
    export GSA_FAKE_PACMAN_CONF_LOG="$ws/pacman-conf.log"
    export GSA_CPU_THREADS=8
    export GSA_MEMORY_GIB=16
}

# write_elf64_needed FILE SONAME — one minimal ET_DYN carrying exactly one
# DT_NEEDED (byte layout after the oracle in crates/gsa-recipe/src/elf.rs;
# e_phentsize 56 and PT_DYNAMIC's p_filesz counting every dyn entry are
# load-bearing). This is the file truth the engine's link filter reads.
write_elf64_needed() {
    local out=$1 soname=$2
    local dynstr_len=$((${#soname} + 2)) dynstr_off=240 total
    total=$((dynstr_off + dynstr_len))
    u16() { printf "$(printf '\\x%02x\\x%02x' $(($1 & 255)) $((($1 >> 8) & 255)))"; }
    u32() {
        printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $(($1 & 255)) $((($1 >> 8) & 255)) \
            $((($1 >> 16) & 255)) $((($1 >> 24) & 255)))"
    }
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

# db_entry DBROOT NAME VERSION [PROVIDE [FILE]] — one fabricated pacman
# local-DB entry (`<db>/local/<name>-<ver>/{desc,files}`), the authority the
# engine's gates resolve against (LocalDb::load through `pacman-conf DBPath`;
# never the host DB). FILE is this fixture's own path MINUS its leading slash:
# the view probes owned files at `/<files-entry>`, so every byte read stays
# under $fixture (tests/gsa-abi-v2.sh `db_file`'s convention).
db_entry() {
    local db=$1 name=$2 version=$3 provide=${4:-} file=${5:-}
    local dir="$db/local/$name-$version"
    mkdir -p "$dir"
    {
        printf '%%NAME%%\n%s\n\n' "$name"
        printf '%%VERSION%%\n%s\n\n' "$version"
        printf '%%BASE%%\n%s\n' "$name"
        if [ -n "$provide" ]; then printf '%%PROVIDES%%\n%s\n' "$provide"; fi
    } >"$dir/desc"
    if [ -n "$file" ]; then
        printf '%%FILES%%\n%s\n' "$file" >"$dir/files"
    else
        printf '%%FILES%%\n' >"$dir/files"
    fi
}

# gsa_archive OUT-DIR NAME [PROVIDE…] — one real .pkg.tar.zst with a complete
# .PKGINFO (the seam reads archive metadata natively and requires pkgname,
# pkgver, arch). Prints the archive path.
gsa_archive() {
    local out=$1 name=$2
    shift 2
    local stage="$out/.stage-$name"
    rm -rf "$stage"
    mkdir -p "$stage"
    {
        printf 'pkgname = %s\n' "$name"
        printf 'pkgbase = %s\n' "$name"
        printf 'pkgver = 1.0.0\n'
        printf 'pkgrel = 1\n'
        printf 'arch = x86_64\n'
        local line
        for line in "$@"; do printf 'provides = %s\n' "$line"; done
    } >"$stage/.PKGINFO"
    tar --zstd -cf "$out/$name-1.0.0-1-x86_64.pkg.tar.zst" -C "$stage" .PKGINFO
    rm -rf -- "$stage"
    printf '%s\n' "$out/$name-1.0.0-1-x86_64.pkg.tar.zst"
}

# rows_only — the §E.2 decision rows of a capture (the seam prints rows
# alone; a run record or prose span would poison the stream and is excluded).
rows_only() {
    awk '
        /^--- run record begin ---/ || /^Build run: / || /^Build order / { exit }
        /^[A-Za-z0-9@._+-]+ (install|skip|refuse|noop|parked) / { print }
    '
}

# want_rows LABEL — the capture's normalized decision rows (rr2_decisions,
# §E.2 → §7 triples) must equal the sorted rows given on stdin exactly.
want_rows() {
    local label=$1 want got
    want=$(sort)
    got=$(printf '%s\n' "$FIXTURE_OUTPUT" | rows_only | rr2_decisions | sort) ||
        fail "$label: malformed §E.2 decision rows:
$FIXTURE_OUTPUT"
    [ "$got" = "$want" ] || fail "$label: decision rows mismatch:
want:
$want
got:
$got
from:
$FIXTURE_OUTPUT"
}

# record_scalar KEY — one scalar of the machine block of the CURRENT capture.
# Inline (never rr2_scalar) for plan records: their `lanes: -` is the §H.2
# format-2-scalar debt (DEVIATION 5).
record_scalar() {
    printf '%s\n' "$FIXTURE_OUTPUT" |
        sed -n '/^--- run record begin ---$/,/^--- run record end ---$/p' |
        sed -n "s/^$1: //p" | head -n 1
}

order_pos() { # $1 = package id; 1-based position in the record's order scalar
    local o p i=0
    o=$(record_scalar order)
    for p in $o; do
        i=$((i + 1))
        [ "$p" = "$1" ] && {
            printf '%s\n' "$i"
            return 0
        }
    done
    return 1
}

# ─── A. toolchain lint (gsa -Ma): cargo/rustc recipes need a rust-git edge ──
(
    set -euo pipefail
    dir="$fixture/audit"
    make_workspace "$dir" 1 2 low
    add_meta_package "$dir" p1 'build() {
    cargo build --release
}'
    add_meta_package "$dir" p2 'build() {
    cargo build --release
}'
    # Comment-only mention: not an invocation, must not fire.
    add_meta_package "$dir" p3 '# historically built with cargo and rustc
build() {
    true
}'
    # rust-git is the toolchain itself and is excepted by the lint.
    add_meta_package "$dir" rust-git 'build() {
    rustc --version
    cargo build --release
}'
    set_topology_record "$dir" p2 git 'rust-git'
    engine_ws "$dir" "$dir/db"

    run_engine "$dir" -Ma
    out_a=$FIXTURE_OUTPUT
    rc_a=$FIXTURE_RC
    [ "$rc_a" -eq 0 ] || fail "A: -Ma failed on a valid workspace (rc=$rc_a):
$out_a"
    # The finding row is the engine's stable keyword line (§B.7; finding
    # strings re-pin to gsa output — the fish prose pin retires, §6).
    grep -Fq 'toolchain-edge p1 uses-cargo/rustc-but-declares-no-rust-git-edge' <<<"$out_a" ||
        fail "A: no toolchain finding for p1 (cargo in build(), no rust-git edge):
$out_a"
    for id in p2 p3 rust-git; do
        if grep -Fq "toolchain-edge $id " <<<"$out_a"; then
            fail "A: false toolchain finding for $id (edge exists / comment only / the toolchain itself):
$out_a"
        fi
    done

    # With the edge declared the finding must disappear, and the exit status
    # must treat a finding exactly like every other audit finding (§E.4
    # report-only: findings never change the exit status).
    set_topology_record "$dir" p1 git 'rust-git'
    run_engine "$dir" -Ma
    out_a2=$FIXTURE_OUTPUT
    rc_a2=$FIXTURE_RC
    [ "$rc_a2" -eq 0 ] || fail "A: -Ma failed after the edge was declared (rc=$rc_a2):
$out_a2"
    # Anchor to the finding-row shape (`<family> <subject> <detail…>`,
    # gsa-maint/src/audit.rs:28). The summary row `audit toolchain-edge clean`
    # also carries the bare keyword, so a substring grep would report the
    # clean verdict as a surviving finding.
    if grep -Eq '^toolchain-edge ' <<<"$out_a2"; then
        fail "A: toolchain finding survived the rust-git edge:
$out_a2"
    fi
    [ "$rc_a2" -eq "$rc_a" ] ||
        fail "A: a finding changed the -Ma exit status ($rc_a -> $rc_a2); §E.4 makes audits report-only either way"
)

# ─── B. ABI-batch policy: the engine's pre-dispatch wave check ─────────────
# The batch data the gate acts on is topology TAGS (abi=must) plus the edge
# direction: llvm-git is the anchor, rust-git its mandatory member. The wave
# engages on an observable token move (binpkg index row ≠ a consumer's
# recorded := token — engine state under GSA_STATE_DIR); B1 seeds exactly
# that.
(
    set -euo pipefail
    dir="$fixture/batch"
    make_workspace "$dir" 1 2 low
    add_meta_package "$dir" llvm-git ''
    add_meta_package "$dir" rust-git ''
    add_meta_package "$dir" q1 ''
    set_topology_record "$dir" llvm-git git '' 'abi=must'
    set_topology_record "$dir" rust-git git 'llvm-git' 'abi=must'
    set_topology_record "$dir" q1 git 'llvm-git'
    engine_ws "$dir" "$dir/db"

    # One stub build pass registers every token in the binpkg index (the
    # engine's own state; GSA_STATE_DIR, never the host's).
    run_engine "$dir" -B --no-prefetch llvm-git rust-git q1
    [ "$FIXTURE_RC" -eq 0 ] || fail "B: the token-registering build pass failed (rc=$FIXTURE_RC):
$FIXTURE_OUTPUT"
    run_engine "$dir" -Qa llvm-git
    tok=$(awk '$1 == "llvm-git" && $2 == "token" { print $3 }' <<<"$FIXTURE_OUTPUT")
    [ -n "$tok" ] || fail "B: -Qa derived no token for llvm-git:
$FIXTURE_OUTPUT"

    # B1: the omitted member RIDES IN (DEVIATION 1). q1 records a STALE token
    # of llvm-git (the observable move); rust-git's own record MATCHES, so
    # only its abi=must batch membership can pull it in — under --leaf, which
    # suppresses consumer expansion. The anchor can never build without its
    # member, and the run builds the complete batch.
    mkdir -p "$GSA_STATE_DIR/abi"
    {
        printf 'q1|0:1.0.0-1|llvm-git|stale-token\n'
        printf 'rust-git|0:1.0.0-1|llvm-git|%s\n' "$tok"
    } >"$GSA_STATE_DIR/abi/subscriptions"
    : >"$GSA_FAKE_MAKEPKG_LOG"
    : >"$GSA_FAKE_PACMAN_LOG"
    run_engine "$dir" -B --no-prefetch --leaf llvm-git
    [ "$FIXTURE_RC" -eq 0 ] ||
        fail "B1: the batch member rode in and the batch must build (rc=$FIXTURE_RC):
$FIXTURE_OUTPUT"
    waves=$(grep '^abi-wave ' <<<"$FIXTURE_OUTPUT" | sort)
    [ "$waves" = "abi-wave llvm-git q1 recorded
abi-wave llvm-git rust-git coupled-must" ] ||
        fail "B1: the wave must drag the stale subscriber (recorded) and the batch member (coupled-must):
$FIXTURE_OUTPUT"
    for id in llvm-git rust-git q1; do
        grep -Fqx "BUILD $id" "$GSA_FAKE_MAKEPKG_LOG" ||
            fail "B1: $id never reached the stub makepkg: $(cat "$GSA_FAKE_MAKEPKG_LOG")"
    done
    rr2_body <<<"$FIXTURE_OUTPUT" >/dev/null ||
        fail "B1: no complete format: 2 run record:
$FIXTURE_OUTPUT"
    llvm_pos=$(order_pos llvm-git) || fail "B1: llvm-git missing from the order scalar"
    rust_pos=$(order_pos rust-git) || fail "B1: rust-git missing from the order scalar"
    [ "$llvm_pos" -lt "$rust_pos" ] ||
        fail "B1: the anchor must build before its member (order: $(record_scalar order))"
    for id in llvm-git rust-git q1; do
        [ "$(rr2_outcome "$id" status <<<"$FIXTURE_OUTPUT")" = succeeded ] ||
            fail "B1: $id did not succeed:
$FIXTURE_OUTPUT"
    done

    # B2: refusal BEFORE dispatch (the KEEP cell :242-244 re-pin). A recorded
    # subscriber the topology has no record for can never be built here, so
    # the plan is under-covered: the run refuses by name (§E.2–E.3), exits 3
    # (§G.1), every row is never-started, and nothing is dispatched.
    printf 'ghost|0:1.0.0-1|llvm-git|stale-token\n' >"$GSA_STATE_DIR/abi/subscriptions"
    : >"$GSA_FAKE_MAKEPKG_LOG"
    : >"$GSA_FAKE_PACMAN_LOG"
    run_engine "$dir" -B --no-prefetch --leaf llvm-git
    [ "$FIXTURE_RC" -eq 3 ] ||
        fail "B2: an under-covered batch must refuse with rc 3 (§G.1), got $FIXTURE_RC:
$FIXTURE_OUTPUT"
    grep -Fxq 'ghost refuse abi-consumer-uncovered llvm-git' <<<"$FIXTURE_OUTPUT" ||
        fail "B2: the refusal is not named per member (§E.3):
$FIXTURE_OUTPUT"
    rr2_body <<<"$FIXTURE_OUTPUT" >/dev/null ||
        fail "B2: a refused run must still carry its full record (§H.1):
$FIXTURE_OUTPUT"
    [ "$(rr2_scalar outcome <<<"$FIXTURE_OUTPUT")" = refused ] ||
        fail "B2: record outcome is $(rr2_scalar outcome <<<"$FIXTURE_OUTPUT"), want refused:
$FIXTURE_OUTPUT"
    [ "$(rr2_scalar rc <<<"$FIXTURE_OUTPUT")" = 3 ] ||
        fail "B2: record rc is $(rr2_scalar rc <<<"$FIXTURE_OUTPUT"), want 3:
$FIXTURE_OUTPUT"
    for id in llvm-git q1 rust-git; do
        [ "$(rr2_outcome "$id" status <<<"$FIXTURE_OUTPUT")" = never-started ] ||
            fail "B2: $id must never start when the plan is refused:
$FIXTURE_OUTPUT"
        [ "$(rr2_outcome "$id" reason <<<"$FIXTURE_OUTPUT")" = abi-consumer-uncovered ] ||
            fail "B2: $id row does not carry the refusal class:
$FIXTURE_OUTPUT"
    done
    derived=$(rr2_remaining <<<"$FIXTURE_OUTPUT" | tr '\n' ' ')
    derived=${derived% }
    [ "$derived" = "$(rr2_continuation remaining <<<"$FIXTURE_OUTPUT")" ] ||
        fail "B2: remaining: disagrees with the rows-derived set [$derived]:
$FIXTURE_OUTPUT"
    [ ! -s "$GSA_FAKE_MAKEPKG_LOG" ] ||
        fail "B2: the refusal came after builds were dispatched: $(cat "$GSA_FAKE_MAKEPKG_LOG")"
    [ ! -s "$GSA_FAKE_PACMAN_LOG" ] ||
        fail "B2: a refused plan reached pacman: $(cat "$GSA_FAKE_PACMAN_LOG")"

    # B3: the dry-run on the SAME refusal state still renders its plan and
    # record and builds nothing — but the gate is selection-level on the
    # engine, so the dry-run refuses with the same class (DEVIATION 7).
    : >"$GSA_FAKE_MAKEPKG_LOG"
    run_engine "$dir" -B --dry-run --leaf llvm-git
    [ "$FIXTURE_RC" -eq 3 ] ||
        fail "B3: the dry-run shares the selection-level refusal class (§G.1), got $FIXTURE_RC:
$FIXTURE_OUTPUT"
    grep -Fq 'Build order (dry run)' <<<"$FIXTURE_OUTPUT" ||
        fail "B3: the dry-run did not render its plan:
$FIXTURE_OUTPUT"
    grep -Fq -- '--- run record begin ---' <<<"$FIXTURE_OUTPUT" ||
        fail "B3: the dry-run did not render its record (§H.1):
$FIXTURE_OUTPUT"
    [ "$(record_scalar outcome)" = planned ] ||
        fail "B3: the plan record is not outcome planned:
$FIXTURE_OUTPUT"
    [ ! -s "$GSA_FAKE_MAKEPKG_LOG" ] ||
        fail "B3: the dry-run dispatched builds: $(cat "$GSA_FAKE_MAKEPKG_LOG")"

    # B4: the listing is untouched (read-only), rc 0.
    run_engine "$dir" -Bl --leaf llvm-git
    [ "$FIXTURE_RC" -eq 0 ] ||
        fail "B4: -Bl on the refused selection failed:
$FIXTURE_OUTPUT"
    grep -Fq 'llvm-git' <<<"$FIXTURE_OUTPUT" ||
        fail "B4: the listing does not name the selection:
$FIXTURE_OUTPUT"
)

# ─── C. dispatcher: mid-run probe after the run's own llvm install ─────────
# FISH-DRIVEN (DEVIATION 2): the engine has no mid-run rustc probe wiring, so
# this section keeps driving the fish builder this workspace carries, with
# the fish-era stubs and byte pins unchanged.
(
    set -euo pipefail
    dir_c="$fixture/dispatch"
    make_workspace "$dir_c" 1 2 low
    make_install_conf "$dir_c/pacman.conf" # the -i run's IgnorePkg registration target (never the host's)
    add_meta_package "$dir_c" llvm-git ''
    add_meta_package "$dir_c" p2 ''
    set_topology_record "$dir_c" p2 git 'llvm-git'
    stub_sudo "$dir_c"

    # The stub build: llvm-git's build "installs" a new LLVM by creating the skew
    # marker; p2's build compiles Rust and dies once the marker exists. This
    # workspace offers no remediation chain (no rust-git package, no core group),
    # so the builder must refuse — stop dispatch BEFORE p2 is ever started.
    cat >"$dir_c/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
id=$(basename "$PWD")
printf 'BUILD %s\n' "$id" >>"${GSA_FAKE_SPAWN_LOG:?}"
if [[ $id == llvm-git ]]; then
    mkdir -p "${GSA_FAKE_MARKER_DIR:?}"
    : >"$GSA_FAKE_MARKER_DIR/llvm-skew"
fi
if [[ $id == p2 ]]; then
    rustc --version || exit 1
fi
: >"$PWD/$id-1.0.0-1-any.pkg.tar.zst"
exit 0
EOF
    chmod +x "$dir_c/bin/makepkg"

    # The stub rustc works until the marker flips, then dies like the real one did.
    cat >"$dir_c/bin/rustc" <<'EOF'
#!/usr/bin/env bash
set -u
if [[ -e ${GSA_FAKE_MARKER_DIR:-/no-such-marker-dir}/llvm-skew ]]; then
    exit 127
fi
exit 0
EOF
    chmod +x "$dir_c/bin/rustc"

    # rust-git counts as installed only after the marker flips (see the header):
    # that is when check_rustc_sanity stops short-circuiting and actually probes.
    cat >"$dir_c/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'pacman %s\n' "$*" >>"${GSA_FAKE_PACMAN_LOG:?}"
case ${1:-} in
-Q)
    if [[ ${2:-} == rust-git &&
        -e ${GSA_FAKE_MARKER_DIR:-/no-such-marker-dir}/llvm-skew ]]; then
        exit 0
    fi
    exit 1
    ;;
-Qp | -Qi) exit 1 ;;
esac
exit 0
EOF
    chmod +x "$dir_c/bin/pacman"

    marker_dir="$dir_c/state/skew"
    mkdir -p "$marker_dir"
    run_builder env \
        PATH="$dir_c/bin:$PATH" \
        GSA_STATE_DIR="$dir_c/state" \
        _IGNOREPKG_CONF="$dir_c/pacman.conf" \
        GSA_FAKE_MARKER_DIR="$marker_dir" \
        GSA_FAKE_SPAWN_LOG="$dir_c/spawn.log" \
        GSA_FAKE_PACMAN_LOG="$dir_c/pacman.log" \
        GSA_CPU_THREADS=8 \
        GSA_MEMORY_GIB=16 \
        fish "$dir_c/build-all.fish" -i llvm-git p2

    if [[ $FIXTURE_RC -eq 0 ]]; then
        printf 'C: the -i run succeeded although its own llvm install broke rustc:\n%s\n' \
            "$FIXTURE_OUTPUT" >&2
        exit 1
    fi
    if grep -Fq 'BUILD p2' "$dir_c/spawn.log" 2>/dev/null; then
        printf 'C: p2 was dispatched after the probe failed:\n%s\n' \
            "$(cat "$dir_c/spawn.log")" >&2
        exit 1
    fi
    if ! grep -Fq 'BUILD llvm-git' "$dir_c/spawn.log" 2>/dev/null; then
        printf 'C: llvm-git never built, so the probe seam was never reached:\n%s\n' \
            "$FIXTURE_OUTPUT" >&2
        exit 1
    fi
    for want in \
        'rustc is BROKEN' \
        "this run's own llvm install broke rustc" \
        'rebuild rust-git in the same pass'; do
        if ! grep -Fq "$want" <<<"$FIXTURE_OUTPUT"; then
            printf 'C: probe-stop message is missing %q:\n%s\n' "$want" "$FIXTURE_OUTPUT" >&2
            exit 1
        fi
    done
    if grep -Fq 'All builds succeeded!' <<<"$FIXTURE_OUTPUT"; then
        printf 'C: success was reported after the probe failure:\n%s\n' "$FIXTURE_OUTPUT" >&2
        exit 1
    fi
)

# ─── D. repo policy: the committed topology orders and tags the batch ───────
# The 2026-09-25 dispatch order let mold-git (a cargo recipe) build before
# rust-git because its edge record was empty. Read-only against the committed
# topology through the engine's `-Qt` data channel (§B.3) — every record is
# id|path|groups|edges|tags, so field 4 is the edge list and field 5 the
# batch tags. Tooling must never parse config/ directly; section F does, and
# deliberately so (it pins the RECORD SHAPE policy, not the data channel).
(
    set -euo pipefail
    export GSA_STATE_DIR="$fixture/state-topo"
    mkdir -p "$GSA_STATE_DIR"
    run_engine "$root" -Qt
    [ "$FIXTURE_RC" -eq 0 ] ||
        fail "D: gsa -Qt failed on the committed config: $FIXTURE_OUTPUT"
    topo_out=$FIXTURE_OUTPUT
    mold_edges=$(awk -F'|' '$1 == "mold-git" { print $4 }' <<<"$topo_out")
    [ -n "$mold_edges" ] || fail "D: no mold-git record in the -Qt output"
    tr ',' '\n' <<<"$mold_edges" | grep -qx 'rust-git' ||
        fail "D: mold-git declares no rust-git edge (got: $mold_edges)"

    # Batch membership is data now, not prose: llvm-git is the anchor and
    # rust-git its mandatory member — both must carry the abi=must tag.
    for id in llvm-git rust-git; do
        tags=$(awk -F'|' -v id="$id" '$1 == id { print $5 }' <<<"$topo_out")
        tr ',' '\n' <<<"$tags" | grep -qx 'abi=must' ||
            fail "D: $id is not tagged abi=must in the committed topology (got: $tags)"
    done

    # The batch must actually order a bare-name selection in CONSUMER
    # direction: selecting X pulls X's transitive consumers, X first.
    # rust-git consumes llvm-git (its edge is the batch's member->anchor
    # direction), so bare llvm-git pulls rust-git in and llvm-git builds
    # BEFORE it. The pair runs on a two-package synthetic topology (where the
    # batch is exactly these two) because the committed tree's llvm-git
    # carries more consumers than the pair. Order comes from the record's
    # `order` scalar (§H.2; inline extraction — DEVIATION 5).
    dir_d="$fixture/order"
    make_workspace "$dir_d" 1 2 low
    add_meta_package "$dir_d" llvm-git ''
    add_meta_package "$dir_d" rust-git ''
    set_topology_record "$dir_d" rust-git git 'llvm-git'
    engine_ws "$dir_d" "$dir_d/db"
    run_engine "$dir_d" -B --dry-run llvm-git
    [ "$FIXTURE_RC" -eq 0 ] ||
        fail "D: dry run of bare llvm-git failed:
$FIXTURE_OUTPUT"
    grep -Fq -- '--- run record begin ---' <<<"$FIXTURE_OUTPUT" ||
        fail "D: the dry run carries no record:
$FIXTURE_OUTPUT"
    llvm_idx=$(order_pos llvm-git) ||
        fail "D: a bare llvm-git selection does not expand to its consumer rust-git:
$FIXTURE_OUTPUT"
    rust_idx=$(order_pos rust-git) ||
        fail "D: a bare llvm-git selection does not expand to its consumer rust-git:
$FIXTURE_OUTPUT"
    [ "$llvm_idx" -lt "$rust_idx" ] ||
        fail "D: llvm-git (index $llvm_idx) does not build before its consumer rust-git (index $rust_idx):
$FIXTURE_OUTPUT"
)

# ─── E. Non-ABI tags keep the severity result at `none` ─────────────────────
# _TAGS carries app-cluster tags as well as ABI tags. A cluster-only record is
# valid and must not produce an empty package_abi_severity result during the
# real-build ABI gate; the combined record below pins that its ABI severity is
# still used when an app-cluster tag is also present. The fish-era prose pins
# retire (DEVIATION 6); the meaning re-pins as the run record.
(
    set -euo pipefail
    dir="$fixture/non-abi-tags"
    make_workspace "$dir" 1 2 low
    add_meta_package "$dir" llvm-git ''
    add_meta_package "$dir" fcitx5-git ''
    add_meta_package "$dir" fcitx5-qt-git ''
    add_meta_package "$dir" untagged-app ''
    add_meta_package "$dir" versioned-app ''
    set_topology_record "$dir" llvm-git core '' 'abi=must'
    set_topology_record "$dir" fcitx5-git app '' 'app-cluster=fcitx5'
    set_topology_record "$dir" fcitx5-qt-git app 'llvm-git' 'abi=should,app-cluster=fcitx5'
    set_topology_record "$dir" untagged-app app ''
    set_topology_record "$dir" versioned-app app '' 'version-sync=nvchecker'
    engine_ws "$dir" "$dir/db"

    # The ABI member stays outside the --leaf selection (the cluster-only,
    # version-sync-only and untagged records must be treated as severity
    # `none` at the same gate). No unrecorded subscriber exists here, so no
    # wave engages and the batch tag never claims the run. The version-sync
    # tag's provider path is pinned by tests/gsa-sync-v2.sh; here the tag
    # only has to be inert for the ABI gate, and without a shipped
    # .nvchecker.toml the engine fails a version-sync pass closed
    # (`sync-refused`, rc 3), so this run passes `--no-sync`.
    run_engine "$dir" -S --leaf --no-sync --config "$dir/pacman.conf" \
        llvm-git fcitx5-git untagged-app versioned-app
    [ "$FIXTURE_RC" -eq 0 ] ||
        fail "E: real build with a cluster-only tag failed (rc=$FIXTURE_RC):
$FIXTURE_OUTPUT"
    rr2_body <<<"$FIXTURE_OUTPUT" >/dev/null ||
        fail "E: no complete format: 2 run record:
$FIXTURE_OUTPUT"
    [ "$(rr2_scalar outcome <<<"$FIXTURE_OUTPUT")" = success ] ||
        fail "E: run record did not report success:
$FIXTURE_OUTPUT"
    for pkg in llvm-git fcitx5-git untagged-app versioned-app; do
        [ "$(rr2_outcome "$pkg" status <<<"$FIXTURE_OUTPUT")" = succeeded ] ||
            fail "E: selected package $pkg did not succeed:
$FIXTURE_OUTPUT"
    done
)

# ─── F. grouping policy: hub/toolchain membership in the topology records ───
# docs/MEMORY.md §1 rule 21 membership tests, one pin per sub-check:
#   a. the compile-toolchain set carries BOTH core and build-tools;
#   b. a package with ≥2 edge-consumers (a record listing X in edges consumes
#      X) carries core, except the rule 21(a) app-cluster exception in F(b)
#      below;
#   c. ripgrep and fd declare a rust-git edge (rule 21(e) — the toolchain-edge
#      discipline the audit lint checks);
#   d. every group named in a record is one of the six roster names, and
#      build-tools is always dual with core.
# The checks read the topology RECORDS themselves — the raw
# id|path|groups|edges[|tags] lines of ${1:-$root/config/topology.conf} — so
# each assertion below owns its own failure message and the optional $1 lets
# a falsification run point them at a scratch copy with one flipped record
# (the repo config is never written). D reads the engine's normalized -Qt
# view; F deliberately reads the two record fields the policy names: groups
# and edges. Engine-independent: unchanged through the flip.
topo_conf=${1:-$root/config/topology.conf}
[[ -f $topo_conf ]] || fail "F: topology file not found: $topo_conf"

# A record is exactly id|path|groups|edges[|tags]; reject any other shape so
# a malformed line can never silently dodge the field checks below.
bad_shape=$(awk -F'|' '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    NF < 4 || NF > 5 { print NR ": " $0 }' "$topo_conf")
[[ -z $bad_shape ]] \
    || fail "F: record is not id|path|groups|edges[|tags]: $bad_shape"

record_field() { # $1 = id, $2 = field number (3 = groups, 4 = edges)
    awk -F'|' -v id="$1" -v f="$2" '$1 == id { print $f }' "$topo_conf"
}

has_member() { # $1 = comma list (groups or edges field), $2 = wanted member
    local item
    local IFS=,
    for item in $1; do
        if [[ $item == "$2" ]]; then
            return 0
        fi
    done
    return 1
}

# a. compile toolchains carry core,build-tools. The set is hard-coded on
# purpose — the toolchain records of the 2026-10-04 migration (docs/NOTE.md);
# a new toolchain record means adding its id here.
toolchain_set=(
    cmake-git gcc-snapshot llvm-git meson-git mold-git qt5-tools qt6-tools
    rocm-llvm rust-git spirv-llvm-translator-git autofdo-git libclc-git
    ninja-git wayland-git rust-bindgen-git ccache
)
for id in "${toolchain_set[@]}"; do
    groups=$(record_field "$id" 3)
    [[ -n $groups ]] || fail "F: toolchain record $id is missing from $topo_conf"
    for want in core build-tools; do
        has_member "$groups" "$want" \
            || fail "F: toolchain $id does not carry $want (groups: $groups)"
    done
done

# b. the hub rule: ≥2 edge-consumers ⇒ core. One exception class, each entry
#   naming its reason:
#   - rule 21(a)'s app-cluster exception: a member whose consumers are all
#     its own app-cluster siblings stays app.
# History of the pin's scope: rule 21(a) and this check were pinned on the
# 2026-10-04 build-tools migration's CURATED build-order edge graph (144
# records), where "a record listing X in edges consumes X" identified ABI
# hubs. The 2026-10-04 topology wiring then replaced that edge set with the
# FULL dependency/supersession graph (653 records / 3373 edges), where a raw
# reverse-edge count no longer identifies ABI-coupled hubs — 204 records had
# ≥2 edge-consumers without carrying `core` — so this fixture narrowed its
# pin with a written-debt register rather than decide the open policy
# question itself. The 2026-10-04 Q2 decision settled that debt the
# enforcing way: all 203 registered records gained `core` dual membership
# (fcitx5-qt-git included — its consumers are NOT all cluster siblings) and
# the register was deleted in the same change, so the bare pin binds over
# the whole graph again. A NEW ≥2-consumer record without `core` fails until
# it carries `core` or its own written exception is added here.
hub_rule_exempt=(
    'fcitx5-git' # rule 21(a) app-cluster exception, preserved as documented by the 2026-10-04 Q2 decision: 5 of its 6 consumers are its own app-cluster=fcitx5 siblings, with stable fcitx5-configtool the known outlier
)
exempt_hub() { # $1 = package id — is it on a hub-rule allow-list?
    local x
    for x in "${hub_rule_exempt[@]}"; do
        if [[ $x == "$1" ]]; then
            return 0
        fi
    done
    return 1
}
while read -r id consumers; do
    if exempt_hub "$id"; then
        continue
    fi
    groups=$(record_field "$id" 3)
    has_member "$groups" core \
        || fail "F: $id has $consumers edge-consumers but does not carry core (groups: $groups)"
done < <(awk -F'|' '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    { n = split($4, e, ",")
      for (i = 1; i <= n; i++) if (e[i] != "") consumers[e[i]]++ }
    END { for (id in consumers) if (consumers[id] >= 2) print id, consumers[id] }
' "$topo_conf" | sort)

# c. toolchain-edge discipline: the two committed cargo recipes name rust-git
# (this is the gap the audit lint flags; D pins mold-git's edge through -Qt).
for id in ripgrep fd; do
    [[ -n $(record_field "$id" 1) ]] \
        || fail "F: no $id record in $topo_conf"
    edges=$(record_field "$id" 4)
    has_member "$edges" rust-git \
        || fail "F: $id declares no rust-git edge (edges: ${edges:-<empty>})"
done

# d. the roster is closed at the six names, and build-tools is ALWAYS dual
# with core (membership is core,build-tools — never build-tools alone).
roster='git,stable,core,misc,app,build-tools'
offenders=$(awk -F'|' -v roster="$roster" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    { n = split($3, g, ",")
      for (i = 1; i <= n; i++) {
          ok = 0
          m = split(roster, r, ",")
          for (j = 1; j <= m; j++) if (g[i] == r[j]) ok = 1
          if (!ok) printf "%s names group '\''%s'\''\n", $1, g[i]
      } }' "$topo_conf")
[[ -z $offenders ]] || fail "F: group outside the roster $roster: $offenders"
offenders=$(awk -F'|' '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    { n = split($3, g, ","); bt = 0; core = 0
      for (i = 1; i <= n; i++) {
          if (g[i] == "build-tools") bt = 1
          if (g[i] == "core") core = 1
      }
      if (bt && !core) print $1 }' "$topo_conf")
[[ -z $offenders ]] \
    || fail "F: build-tools without core (membership is always dual core,build-tools): $offenders"

# ─── G. soname drift at the §E.2 decision seam ─────────────────────────────
# The fish layer-2 gate (a provider whose soname-provides set differs from
# the installed stock package's provides must rebuild its DIRECT in-tree
# surface consumers in the same selection) re-pins at the hidden
# `gsa --install-decide` seam (§D.1): the refusal rows name the drifted
# surface (`refuse abi-soname …`) and exactly the uncovered consumers that
# LINK the moving soname (`refuse abi-consumer … <consumer>`), covered
# consumers ride the transaction, and an uninstalled consumer never gates.
# The consumer relation's link-truth half (2026-10-07 gate fix v2: naming a
# provider is not linking it) is the ELF file truth the view probes. The
# seam touches nothing (§D.1) — the KEEP "nothing dispatched before it
# decides" keeps as its pacman/sudo/makepkg silence plus rc §E.5.
(
    set -euo pipefail
    dir="$fixture/abi-drift"
    make_workspace "$dir" 1 2 low
    engine_ws "$dir" "$dir/db"
    mkdir -p "$dir/elf" "$dir/archives"

    # Link truth: app-git and mid-git LINK the stock soname the swap removes
    # (`libgreet.so.1-64`); leaf-git links only its mid-git provider; nlink-git
    # links libc — it names libs-git but can never break on libgreet moving.
    write_elf64_needed "$dir/elf/app.so" 'libgreet.so.1-64'
    write_elf64_needed "$dir/elf/mid.so" 'libgreet.so.1-64'
    write_elf64_needed "$dir/elf/leaf.so" 'libmid-git.so.1'
    write_elf64_needed "$dir/elf/nlink.so" 'libc.so.6'

    # The installed stock surface `libs` carries libgreet.so=1-64; the house
    # build moves it to 2-64 (the G1/G2/G5/G6 trigger) or keeps it (G3).
    a_libs=$(gsa_archive "$dir/archives" libs-git 'libgreet.so=2-64')
    a_same=$(gsa_archive "$dir/archives" libs-git-same 'libgreet.so=1-64')
    a_app=$(gsa_archive "$dir/archives" app-git 'libapp.so=1-64')
    a_mid=$(gsa_archive "$dir/archives" mid-git 'libmid-git.so=1-64')

    # G1 + G5 (the one-hop / link-truth boundary): the drifted surface with
    # its linked consumers installed and OUTSIDE the transaction refuses
    # naming provider, drift and exactly the missing LINKERS — never
    # leaf-git (a consumer of a consumer links the provider's soname only
    # through its own provider) and never nlink-git (names the provider over
    # both relation halves but links nothing of the moving soname). This is
    # the fish 'missing: app-git' / 'missing: mid-git' meaning re-pinned as
    # §E.2 rows (prose retired, §L.3).
    db_entry "$dir/db" libs 1-1 'libgreet.so=1-64'
    db_entry "$dir/db" app-git 1-1 '' "${dir#/}/elf/app.so"
    db_entry "$dir/db" mid-git 1-1 '' "${dir#/}/elf/mid.so"
    db_entry "$dir/db" leaf-git 1-1 '' "${dir#/}/elf/leaf.so"
    db_entry "$dir/db" nlink-git 1-1 '' "${dir#/}/elf/nlink.so"
    : >"$GSA_FAKE_PACMAN_LOG"
    : >"$GSA_FAKE_SUDO_LOG"
    : >"$GSA_FAKE_MAKEPKG_LOG"
    run_engine "$dir" --install-decide checked "$a_libs"
    [ "$FIXTURE_RC" -eq 1 ] ||
        fail "G1: a drifted surface with uncovered linked consumers must refuse (rc §E.5 1), got $FIXTURE_RC:
$FIXTURE_OUTPUT"
    want_rows G1 <<'EOF'
libs-git refuse abi-consumer
libs-git refuse abi-consumer
libs-git refuse abi-soname
EOF
    grep -Fq "abi-soname $a_libs libs-git libgreet.so 1-64 2-64" <<<"$FIXTURE_OUTPUT" ||
        fail "G1: the drift row does not name both provide sides:
$FIXTURE_OUTPUT"
    grep -Fq "abi-consumer $a_libs app-git" <<<"$FIXTURE_OUTPUT" ||
        fail "G1: the refusal does not name the missing linker app-git:
$FIXTURE_OUTPUT"
    grep -Fq "abi-consumer $a_libs mid-git" <<<"$FIXTURE_OUTPUT" ||
        fail "G1: the refusal does not name the missing linker mid-git:
$FIXTURE_OUTPUT"
    if printf '%s\n' "$FIXTURE_OUTPUT" | rows_only | grep -Fq 'leaf-git'; then
        fail "G1: the hub chain leaked a non-linking member into the refusal:
$FIXTURE_OUTPUT"
    fi
    if printf '%s\n' "$FIXTURE_OUTPUT" | rows_only | grep -Fq 'nlink-git'; then
        fail "G1: a naming-but-not-linking consumer leaked into the refusal:
$FIXTURE_OUTPUT"
    fi
    [ ! -s "$GSA_FAKE_PACMAN_LOG" ] ||
        fail "G1: a refused plan reached pacman: $(cat "$GSA_FAKE_PACMAN_LOG")"
    [ ! -s "$GSA_FAKE_SUDO_LOG" ] ||
        fail "G1: a refused plan escalated through sudo: $(cat "$GSA_FAKE_SUDO_LOG")"
    [ ! -s "$GSA_FAKE_MAKEPKG_LOG" ] ||
        fail "G1: the seam dispatched builds: $(cat "$GSA_FAKE_MAKEPKG_LOG")"

    # G2: the covered closure — the consumer's archive rides the same
    # transaction, so no `abi-consumer` refusal may name it (rule 25(d)
    # in-run repair coverage). DEVIATION 3: the engine's provide gate still
    # refuses the MOVING surface itself (`refuse abi-soname`), where the fish
    # gate planned clean — the coverage half keeps, the drift-alone half
    # flips fail-closed.
    rm -rf "$dir/db"
    mkdir -p "$dir/db/local"
    db_entry "$dir/db" libs 1-1 'libgreet.so=1-64'
    db_entry "$dir/db" app-git 1-1 '' "${dir#/}/elf/app.so"
    run_engine "$dir" --install-decide checked "$a_libs" "$a_app"
    [ "$FIXTURE_RC" -eq 1 ] ||
        fail "G2: the engine refuses the moving surface even covered (DEVIATION 3), got $FIXTURE_RC:
$FIXTURE_OUTPUT"
    want_rows G2 <<'EOF'
app-git install ok
libs-git refuse abi-soname
EOF
    if printf '%s\n' "$FIXTURE_OUTPUT" | rows_only | grep -Fq 'abi-consumer'; then
        fail "G2: a covered consumer was named in a refusal:
$FIXTURE_OUTPUT"
    fi

    # G3: unchanged surface ⇒ no drift, no gate — the provider plans clean
    # even with the consumer installed and omitted (the auto-versioned form
    # of the same bare stem compares equal).
    rm -rf "$dir/db"
    mkdir -p "$dir/db/local"
    db_entry "$dir/db" libs 1-1 'libgreet.so=1-64'
    db_entry "$dir/db" app-git 1-1 '' "${dir#/}/elf/app.so"
    run_engine "$dir" --install-decide checked "$a_same"
    [ "$FIXTURE_RC" -eq 0 ] ||
        fail "G3: an unchanged surface must not gate (rc=$FIXTURE_RC):
$FIXTURE_OUTPUT"
    want_rows G3 <<'EOF'
libs-git-same install ok
EOF

    # G4: drifted surface but the consumer is NOT installed ⇒ nothing to
    # protect: no `abi-consumer` row may exist. DEVIATION 3: the fish gate
    # built the provider clean here; the engine's provide gate refuses the
    # drift itself — the consumer-negative half keeps exactly.
    rm -rf "$dir/db"
    mkdir -p "$dir/db/local"
    db_entry "$dir/db" libs 1-1 'libgreet.so=1-64'
    run_engine "$dir" --install-decide checked "$a_libs"
    [ "$FIXTURE_RC" -eq 1 ] ||
        fail "G4: the engine refuses the drift itself (DEVIATION 3), got $FIXTURE_RC:
$FIXTURE_OUTPUT"
    want_rows G4 <<'EOF'
libs-git refuse abi-soname
EOF
    if printf '%s\n' "$FIXTURE_OUTPUT" | rows_only | grep -Fq 'abi-consumer'; then
        fail "G4: an uninstalled consumer produced a refusal row:
$FIXTURE_OUTPUT"
    fi

    # G6: the direct surface consumers covered ⇒ the whole linked set rides
    # the transaction; leaf-git and nlink-git stay untouched (never dragged
    # in, never named) — a non-linking consumer of a consumer is not part of
    # the batch. DEVIATION 3 applies to the drift row.
    rm -rf "$dir/db"
    mkdir -p "$dir/db/local"
    db_entry "$dir/db" libs 1-1 'libgreet.so=1-64'
    db_entry "$dir/db" app-git 1-1 '' "${dir#/}/elf/app.so"
    db_entry "$dir/db" mid-git 1-1 '' "${dir#/}/elf/mid.so"
    db_entry "$dir/db" leaf-git 1-1 '' "${dir#/}/elf/leaf.so"
    db_entry "$dir/db" nlink-git 1-1 '' "${dir#/}/elf/nlink.so"
    run_engine "$dir" --install-decide checked "$a_libs" "$a_app" "$a_mid"
    [ "$FIXTURE_RC" -eq 1 ] ||
        fail "G6: the engine refuses the moving surface even covered (DEVIATION 3), got $FIXTURE_RC:
$FIXTURE_OUTPUT"
    want_rows G6 <<'EOF'
app-git install ok
libs-git refuse abi-soname
mid-git install ok
EOF
    if printf '%s\n' "$FIXTURE_OUTPUT" | rows_only | grep -Eq 'leaf-git|nlink-git'; then
        fail "G6: a non-linking package was dragged into the batch:
$FIXTURE_OUTPUT"
    fi
)

# ─── H. gate COST at synthetic scale: probe-count bounds ───────────────────
# H4 (engine): the decision pass consults the installed DB exactly once for
# the whole pass (memoised by construction — DEVIATION 4) and the scale
# decisions keep. The fish section below keeps the per-name probe pins
# against the fish gate.
(
    set -euo pipefail
    dir="$fixture/gate-cost-engine"
    make_workspace "$dir" 1 2 low
    engine_ws "$dir" "$dir/db"
    mkdir -p "$dir/elf" "$dir/archives"

    # The ONE installed stock surface is h-drift (libgone.so=1-64); the 240
    # members LINK its soname, so a provider whose build drops the soname
    # strands exactly those 240 as uncovered linked consumers. The gate's
    # 3 × 240 = 720 (provider × member) visits must not fork per visit.
    db_entry "$dir/db" h-drift 1-1 'libgone.so=1-64'
    members=()
    for num in $(seq -w 1 240); do
        id="h-mem$num"
        write_elf64_needed "$dir/elf/$id.so" 'libgone.so.1-64'
        db_entry "$dir/db" "$id" 1-1 '' "${dir#/}/elf/$id.so"
        members+=("$id")
    done
    provs=()
    flavors=()
    n=0
    for flavor in git hg snapshot; do
        n=$((n + 1))
        provs+=("$(gsa_archive "$dir/archives" "h-drift-$flavor" "libp$n.so")")
        flavors+=("h-drift-$flavor")
    done

    : >"$GSA_FAKE_PACMAN_CONF_LOG"
    : >"$GSA_FAKE_PACMAN_LOG"
    : >"$GSA_FAKE_SUDO_LOG"
    : >"$GSA_FAKE_MAKEPKG_LOG"
    run_engine "$dir" --install-decide checked "${provs[@]}"
    [ "$FIXTURE_RC" -eq 1 ] ||
        fail "H4: drifted providers with uncovered linked consumers must refuse (rc=$FIXTURE_RC):
$FIXTURE_OUTPUT"
    rows=$(printf '%s\n' "$FIXTURE_OUTPUT" | rows_only)
    for n in 1 2 3; do
        subj=${flavors[$((n - 1))]}
        soname_rows=$(grep -c "$subj refuse abi-soname " <<<"$rows" || true)
        [ "$soname_rows" = 1 ] ||
            fail "H4: $subj wants exactly one abi-soname row, saw $soname_rows"
        # `abi-soname <archive> <pkgname> <name> <inst_ver> <built_ver>`
        # (gsa-abi/src/rows.rs:171) — the changed-surface shape: the house
        # build ships libpN.so where the installed stock carried libgone.so,
        # so the built side of libgone.so is absent and renders `-`.
        grep -Fq "abi-soname ${provs[$((n - 1))]} $subj libgone.so 1-64 -" <<<"$rows" ||
            fail "H4: $subj's drift row does not name the disappearing surface:
$rows"
    done
    # The decision half at scale: the named consumer set is exactly the 240
    # linked members — nothing dropped, nothing extra — and every provider
    # names all of them. The row is
    # `<subject> refuse abi-consumer <archive> <consumer>`, so the consumer
    # is field 5.
    named=$(printf '%s\n' "$rows" | awk '$3 == "abi-consumer" { print $5 }' | sort -u)
    [ "$named" = "$(printf '%s\n' "${members[@]}" | sort)" ] ||
        fail "H4: the refusal's consumer set is not exactly the 240 linked members:
$(printf '%s\n' "$named" | tr '\n' ' ')"
    consumer_rows=$(grep -c ' refuse abi-consumer ' <<<"$rows" || true)
    [ "$consumer_rows" = 720 ] ||
        fail "H4: want 720 abi-consumer rows (3 providers × 240 linked members), saw $consumer_rows"

    # The cost bound: one installed-DB consult for the whole decision pass,
    # and the seam touches no pacman/sudo/makepkg at all.
    conf_calls=$(wc -l <"$GSA_FAKE_PACMAN_CONF_LOG")
    [ "$conf_calls" = 1 ] ||
        fail "H4: want exactly 1 pacman-conf DBPath consult per decision pass, saw $conf_calls:
$(cat "$GSA_FAKE_PACMAN_CONF_LOG")"
    [ ! -s "$GSA_FAKE_PACMAN_LOG" ] ||
        fail "H4: the seam is pacman-free (rule 25(h)): $(cat "$GSA_FAKE_PACMAN_LOG")"
    [ ! -s "$GSA_FAKE_SUDO_LOG" ] ||
        fail "H4: the seam escalated through sudo: $(cat "$GSA_FAKE_SUDO_LOG")"
    [ ! -s "$GSA_FAKE_MAKEPKG_LOG" ] ||
        fail "H4: the seam dispatched builds: $(cat "$GSA_FAKE_MAKEPKG_LOG")"
)

# ─── H (fish era): the keyed gate helpers' per-name probe counts ───────────
# FISH-DRIVEN (DEVIATION 4): the per-(anchor × member) probe channel exists
# only in the fish builder's keyed gate helpers. Pinned by COUNTING the stub
# pacman's argv log (never by wall-clock timing, which flakes).
(
    set -euo pipefail
    dir_h="$fixture/abi-gate-cost"
    # 8 lanes, not the usual 1: H2 builds the complete 244-package batch and
    # the dispatcher starts at most one package per lane per 0.5 s poll cycle,
    # so a single lane turns those stub builds into minutes of pure dispatch
    # latency. Nothing asserted below depends on the lane count or the build
    # order: H1/H3 are pre-dispatch refusals counted as probe forks, and H2
    # counts dispatches as an unordered set.
    make_workspace "$dir_h" 8 2 low

    # anchors: abi=must with no abi-tagged dependency — the batch origins.
    # providers: UNTAGGED (the tag gate must never claim them, or layer 2
    # would be unreachable behind the tag refusal) and three VCS flavors of
    # ONE stock name — abi_stock_name maps h-drift-{git,hg,snapshot} all to
    # h-drift, so an unmemoised abi_installed_provides would fork the same
    # `pacman -Qi -- h-drift` once per provider while the memo forks it once.
    # Their house provides (libpN.so) differ from the installed surface the
    # stub reports for h-drift (libgone.so) — G1's changed-surface trigger.
    anchors=()
    for n in 1 2 3 4; do
        add_meta_package "$dir_h" "h-anchor$n" ''
        set_topology_record "$dir_h" "h-anchor$n" git '' 'abi=must'
        anchors+=("h-anchor$n")
    done
    providers=()
    n=0
    for flavor in git hg snapshot; do
        n=$((n + 1))
        add_meta_package "$dir_h" "h-prov$n" ''
        set_topology_record "$dir_h" "h-prov$n" git '' ''
        {
            printf 'pkgbase = h-drift-%s\n' "$flavor"
            printf 'pkgname = h-drift-%s\n' "$flavor"
            printf '\tprovides = libp%d.so\n' "$n"
        } >"$dir_h/packages/h-prov$n/.SRCINFO"
        providers+=("h-prov$n")
    done

    # members: abi=must, consuming EVERY anchor and EVERY provider — the one
    # shared pool that is each anchor's tag batch and each provider's layer-2
    # consumer closure at once. Written by one direct loop (two-line PKGBUILD,
    # .SRCINFO, record — byte-identical to what add_meta_package +
    # set_topology_record produce) because those helpers rewrite the whole
    # topology file per record: O(n²) forks at 240 packages, which would
    # dominate this fixture's runtime.
    member_edges='h-anchor1,h-anchor2,h-anchor3,h-anchor4,h-prov1,h-prov2,h-prov3'
    mkdir -p "$dir_h"/packages/h-mem{001..240}
    members=()
    for num in $(seq -w 1 240); do
        id="h-mem$num"
        {
            printf 'pkgname=%s\n' "$id"
            printf '%s\n' "$gsa_meta_any"
        } >"$dir_h/packages/$id/PKGBUILD"
        {
            printf 'pkgbase = %s\n' "$id"
            printf 'pkgname = %s\n' "$id"
            printf '\tdepends = libp1.so\n'
            printf '\tdepends = libp2.so\n'
            printf '\tdepends = libp3.so\n'
        } >"$dir_h/packages/$id/.SRCINFO"
        printf '%s|packages/%s|git|%s|abi=must\n' \
            "$id" "$id" "$member_edges" >>"$dir_h/config/topology.conf"
        members+=("$id")
    done

    stub_sudo "$dir_h"

    # The stub pacman logs EVERY argv (the cost channel: counts, never timing)
    # and strips the leading `--` before answering. Installed = the shared
    # member pool (both refusal preconditions); the ONE installed stock
    # surface is h-drift, answering G's changed-surface shape
    # (`libgone.so=1-64` against the house `libpN.so`).
    cat >"$dir_h/bin/pacman" <<'EOF'
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
    [[ ${args[1]:-} == h-drift ]] || exit 1
    printf 'Name : h-drift\nVersion : 1-1\nProvides : libgone.so=1-64\n'
    exit 0
    ;;
-Q)
    [[ ${args[1]:-} == h-mem* ]] && exit 0
    exit 1
    ;;
-Ql)
    # File listing for the link-truth probe: one synthetic ELF path per
    # member; the readelf stub answers its DT_NEEDED.
    [[ ${args[1]:-} == h-mem* ]] || exit 1
    printf '%s /usr/lib/lib-%s.so\n' "${args[1]}" "${args[1]}"
    ;;
esac
exit 1
EOF
    chmod +x "$dir_h/bin/pacman"

    # The stub readelf: every member LINKS the stock soname the drift removes
    # (`libgone.so=1-64`) — the link-truth filter keeps all 240 in the batch.
    cat >"$dir_h/bin/readelf" <<'EOF'
#!/usr/bin/env bash
set -u
for a in "$@"; do
    [[ $a == -* ]] && continue
    printf 'File: %s\n' "$a"
    printf ' 0x0000000000000001 (NEEDED)             Shared library: [libgone.so.1-64]\n'
done
exit 0
EOF
    chmod +x "$dir_h/bin/readelf"

    # The stub makepkg: B/G's shape — a BUILD marker plus the trivial archive.
    cat >"$dir_h/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
id=$(basename "$PWD")
printf 'BUILD %s\n' "$id" >>"${GSA_FAKE_MAKEPKG_LOG:?}"
: >"$PWD/$id-1.0.0-1-any.pkg.tar.zst"
exit 0
EOF
    chmod +x "$dir_h/bin/makepkg"

    run_env_h() {
        run_builder env \
            PATH="$dir_h/bin:$PATH" \
            GSA_STATE_DIR="$dir_h/state" \
            GSA_FAKE_PACMAN_LOG="$dir_h/pacman.log" \
            GSA_FAKE_MAKEPKG_LOG="$dir_h/makepkg.log" \
            GSA_CPU_THREADS=8 \
            GSA_MEMORY_GIB=16 \
            fish "$dir_h/build-all.fish" "$@"
    }

    # Probe-count oracles over the stub's argv log. The gate spells its probes
    # two ways — abi_id_installed passes `pacman -Q NAME` positionally (the
    # contract the fixture stubs read), abi_pkg_installed /
    # abi_installed_provides pass the `--` separator — so the oracles count
    # `pacman OP [--] NAME` probe lines by NAME regardless of the separator:
    # the bound is on FORKS per unique name, not on argv spelling. probe_once
    # asserts the memoisation bound (every probed name appears EXACTLY once —
    # a name never probed is a saved fork and vacuously satisfies the bound);
    # probe_count pins the scenario totals — the memo must collapse repeated
    # visits to one probe per unique name, never drop a probe the decision
    # depends on.
    probe_once() { # $1 = log, $2 = op (-Q|-Qi), $3 = scenario label
        local offenders
        offenders=$(awk -v op="$2" '
            $1 == "pacman" && $2 == op {
                name = ($3 == "--" ? $4 : $3)
                if (name != "") n[name]++
            }
            END { for (k in n) if (n[k] != 1) printf "%s probed %d time(s)\n", k, n[k] }' "$1" \
            | sort)
        [[ -z $offenders ]] \
            || fail "$3: pacman $2 probe not once per unique name: $offenders"
    }
    probe_count() { # $1 = log, $2 = op (-Q|-Qi) — probe lines seen
        awk -v op="$2" '
            $1 == "pacman" && $2 == op {
                name = ($3 == "--" ? $4 : $3)
                if (name != "") n++
            }
            END { print n + 0 }' "$1"
    }
    q_probes() { # $1 = log — the probed -Q names, sorted
        awk '
            $1 == "pacman" && $2 == "-Q" {
                name = ($3 == "--" ? $4 : $3)
                if (name != "") print name
            }' "$1" | sort
    }

    # H1 — the tag gate's cost pin. Only the 4 anchors are selected
    # (--no-deps keeps the members out) and every member is installed:
    # 4 × 240 = 960 (anchor, member) visits must collapse to ONE
    # `pacman -Q <id>` probe per unique member id (the old gate forked a
    # pacman per visit). The decision is B1's refusal verbatim, at scale.
    : >"$dir_h/pacman.log"
    : >"$dir_h/makepkg.log"
    run_env_h --no-deps --no-sync --allow-broken-rustc "${anchors[@]}"
    [[ $FIXTURE_RC -ne 0 ]] \
        || fail "H1: the anchors without their shared members were allowed to build: $FIXTURE_OUTPUT"
    for want in \
        'refusing to build h-anchor1 without h-mem001' \
        'abi=must batch anchor' \
        'rebuild in the same selection' \
        'rebuild h-mem001 in the same run' \
        'check_rustc_sanity recovery text'; do
        if ! grep -Fq "$want" <<<"$FIXTURE_OUTPUT"; then
            fail "H1: refusal message is missing $want: $FIXTURE_OUTPUT"
        fi
    done
    if [[ -s "$dir_h/makepkg.log" ]]; then
        fail "H1: the refusal came after builds were dispatched: $(cat "$dir_h/makepkg.log")"
    fi
    probe_once "$dir_h/pacman.log" -Q H1
    [[ $(probe_count "$dir_h/pacman.log" -Q) == 240 ]] \
        || fail "H1: want exactly 240 pacman -Q probes (one per shared member across 960 anchor×member visits), saw $(probe_count "$dir_h/pacman.log" -Q)"
    [[ $(q_probes "$dir_h/pacman.log") == "$(printf '%s\n' "${members[@]}" | sort)" ]] \
        || fail "H1: the probed id set is not exactly the 240 shared members: $(q_probes "$dir_h/pacman.log" | tr '\n' ' ')"
    [[ $(probe_count "$dir_h/pacman.log" -Qi) == 0 ]] \
        || fail "H1: the tag-gate refusal must stop before layer 2 probes pacman -Qi: $(cat "$dir_h/pacman.log")"

    # H2 — the decision half at scale: the same anchors WITHOUT --no-deps.
    # Consumer expansion rides the 240 members in (they consume the anchors),
    # the batch is complete, and all 244 packages build. A complete batch
    # must probe pacman ZERO times: every member is in the selection, so the
    # memoised helpers are never reached.
    : >"$dir_h/pacman.log"
    : >"$dir_h/makepkg.log"
    run_env_h --no-sync --allow-broken-rustc "${anchors[@]}"
    [[ $FIXTURE_RC -eq 0 ]] && grep -Fq 'All builds succeeded!' <<<"$FIXTURE_OUTPUT" \
        || fail "H2: the complete batch was refused or failed: $FIXTURE_OUTPUT"
    built=$(awk '/^BUILD / { n++ } END { print n + 0 }' "$dir_h/makepkg.log")
    [[ $built == 244 ]] \
        || fail "H2: want 244 stub makepkg dispatches (4 anchors + 240 members), saw $built"
    absent=$(printf '%s\n' "${anchors[@]}" "${members[@]}" | sort \
        | comm -23 - <(awk '/^BUILD / { print $2 }' "$dir_h/makepkg.log" | sort -u))
    [[ -z $absent ]] || fail "H2: never reached the stub makepkg: $absent"
    [[ $(probe_count "$dir_h/pacman.log" -Q) == 0 ]] \
        || fail "H2: a complete batch must not probe pacman -Q: $(cat "$dir_h/pacman.log")"
    [[ $(probe_count "$dir_h/pacman.log" -Qi) == 0 ]] \
        || fail "H2: a complete batch must not probe pacman -Qi: $(cat "$dir_h/pacman.log")"

    # H3 — the layer-2 helpers' cost pin. Only the 3 drift providers are
    # selected (untagged, so the tag gate stays silent) and all 240 members
    # are omitted and installed: 3 × 240 = 720 (provider, member) closure
    # visits must collapse to one `pacman -Q` probe per member id, and the
    # three same-stock-name providers' surface probes must collapse to ONE
    # `pacman -Qi -- h-drift`. The decision is G1's refusal verbatim, at scale.
    : >"$dir_h/pacman.log"
    : >"$dir_h/makepkg.log"
    run_env_h --no-deps --no-sync --allow-broken-rustc "${providers[@]}"
    [[ $FIXTURE_RC -ne 0 ]] \
        || fail "H3: drifted providers with omitted installed consumers built: $FIXTURE_OUTPUT"
    for want in \
        'refusing to build h-prov1 without h-mem001' \
        'soname provides changed' \
        'missing: h-mem001' \
        'add h-mem001 to the selection'; do
        if ! grep -Fq "$want" <<<"$FIXTURE_OUTPUT"; then
            fail "H3: refusal message is missing $want: $FIXTURE_OUTPUT"
        fi
    done
    if [[ -s "$dir_h/makepkg.log" ]]; then
        fail "H3: the refusal came after builds were dispatched: $(cat "$dir_h/makepkg.log")"
    fi
    probe_once "$dir_h/pacman.log" -Q H3
    [[ $(probe_count "$dir_h/pacman.log" -Q) == 240 ]] \
        || fail "H3: want exactly 240 pacman -Q probes (one per shared member across 720 provider×member visits), saw $(probe_count "$dir_h/pacman.log" -Q)"
    [[ $(q_probes "$dir_h/pacman.log") == "$(printf '%s\n' "${members[@]}" | sort)" ]] \
        || fail "H3: the probed id set is not exactly the 240 shared members: $(q_probes "$dir_h/pacman.log" | tr '\n' ' ')"
    probe_once "$dir_h/pacman.log" -Qi H3
    [[ $(probe_count "$dir_h/pacman.log" -Qi) == 1 ]] \
        || fail "H3: want exactly 1 pacman -Qi probe (h-drift, memoised across the 3 VCS flavors), saw $(probe_count "$dir_h/pacman.log" -Qi)"
)

printf 'abi-batch-policy fixture: PASS\n'
