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
# Eight policy seams are pinned here, one section each:
#
#   A. --audit toolchain lint: a recipe whose PKGBUILD invokes cargo/rustc
#      must name rust-git in its topology record's edges field (rust-git
#      itself excepted).
#   B. ABI-batch refusal (generic): a REAL build whose selection contains an
#      abi=must batch anchor (llvm-git) while an installed abi=must batch
#      member (rust-git) is omitted is refused up front; the read-only modes
#      (-n, -l) stay unaffected. Batch membership is topology data — the
#      tags field (abi=must / abi=should) plus the edge direction. Since
#      consumer expansion landed, a bare llvm-git can never omit its member
#      (rust-git consumes llvm-git and rides in automatically), so the
#      refusal is reachable only through --no-deps.
#   C. Dispatcher probe: with -i, a successful lane for llvm-git re-runs
#      check_rustc_sanity BEFORE anything else dispatches. Since 2026-10-02 a
#      failing probe FORCE-BUILDS the at-risk chain (remediation-by-rebuild,
#      see tests/toolchain-remediation.sh); this workspace has no identifiable
#      remediation chain at all (no rust-git package, no core group), so it
#      pins the remaining refusal: stop dispatch, drain in-flight lanes, exit
#      non-zero.
#   D. Repo policy: config/topology.conf declares mold-git's rust-git edge
#      (the missing edge that let a cargo recipe dispatch before rust-git),
#      a bare-name selection pulls its abi-coupled partner in build order
#      (llvm-git before its consumer rust-git), and the llvm-git /
#      rust-git batch membership is recorded as tags. Read through the
#      builder's --topology data channel — the same interface
#      tests/srcinfo-freshness.sh consumes.
#   E. Non-ABI tags: app-cluster/version-sync-only records keep the ABI
#      severity result at `none` at the real-build gate.
#   F. Grouping policy: the committed topology's group discipline
#      (docs/MEMORY.md §1 rule 21) — every compile-toolchain record carries
#      core,build-tools; every package with ≥2 edge-consumers carries core
#      (sole allow-list: the rule 21(a) app-cluster exception — the Q2-open
#      register was deleted when the 2026-10-04 Q2 decision landed its 203
#      ids as core dual membership, see section F(b)); ripgrep and fd
#      declare a rust-git edge; groups stay inside the six-name roster and
#      build-tools is always dual with core. These checks read the topology
#      RECORDS raw (the id|path|groups|edges[|tags] lines) from the optional
#      $1 path — default config/topology.conf — so a falsification run points
#      them at a scratch copy with one flipped record; the repo file is
#      never mutated.
#   G. ABI-drift batch tightening (the guard's layer 2): a provider whose
#      soname-provides set (committed .SRCINFO bare stems) differs from the
#      installed stock package's provides refuses a real build that omits an
#      installed member of its in-tree consumer closure (--no-deps keeps the
#      omission reachable); the complete closure builds, and an unchanged
#      surface or an uninstalled consumer never gates.
#   H. Pre-dispatch gate COST at synthetic scale: the keyed/memoized gate
#      helpers keep the pacman probe count bounded — one installed-member
#      probe (`pacman -Q <id>`) per unique member id across ALL (anchor ×
#      member) visits, one stock-surface probe (`pacman -Qi <name>`) per
#      unique name — pinned by COUNTING the stub pacman's argv log (never by
#      wall-clock timing, which flakes), while B's refusal and G's layer-2
#      refusal are re-asserted at 247 synthetic packages and a complete
#      batch still builds.
#
# Synthetic workspaces + PATH stubs only; nothing real is built or installed.
#
# Section C's stubs key off one marker file the fake llvm-git build creates.
# The stub pacman reports rust-git as installed ONLY once that marker exists:
# the ABI-batch gate (section B) refuses a [llvm-git, …] selection whenever
# rust-git is installed and absent from it, so with a static "installed"
# answer this very selection could never reach the dispatcher. The flip
# models the incident timeline — the system rustc only became broken (and
# worth probing) when this run's own llvm install landed.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-abi-batch.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    printf 'abi-batch-policy fixture: %s\n' "$*" >&2
    exit 1
}

# Synthetic packages carry the 1.0.0-1-any metadata their stubs' archive names
# assume; the helper's add_package writes a one-line PKGBUILD, so that metadata
# rides in as extra-pkglines via gsa_meta_any. run_builder (output+status in
# FIXTURE_OUTPUT/FIXTURE_RC) comes from the helper.
add_meta_package() { # $1 = dir, $2 = id, $3 = extra PKGBUILD body (may be empty)
    local extra=$gsa_meta_any
    [[ -n ${3:-} ]] && extra+=$'\n'"$3"
    add_package "$1" "$2" "$extra"
}

# ─── A. --audit lint: cargo/rustc recipes need a rust-git edge ───────────────
dir_a="$fixture/audit"
make_workspace "$dir_a" 1 2 low
add_meta_package "$dir_a" p1 'build() {
    cargo build --release
}'
add_meta_package "$dir_a" p2 'build() {
    cargo build --release
}'
# Comment-only mention: not an invocation, must not fire.
add_meta_package "$dir_a" p3 '# historically built with cargo and rustc
build() {
    true
}'
# rust-git is the toolchain itself and is excepted by the lint.
add_meta_package "$dir_a" rust-git 'build() {
    rustc --version
    cargo build --release
}'
set_topology_record "$dir_a" p2 git 'rust-git'

run_builder fish "$dir_a/build-all.fish" --audit
out_a=$FIXTURE_OUTPUT
rc_a=$FIXTURE_RC
if [[ $rc_a -ne 0 ]]; then
    printf 'A: --audit failed on a valid workspace (rc=%d):\n%s\n' "$rc_a" "$out_a" >&2
    exit 1
fi
if ! grep -Fq 'toolchain: p1 uses cargo/rustc but declares no rust-git edge' <<<"$out_a"; then
    printf 'A: no toolchain finding for p1 (cargo in build(), no rust-git edge):\n%s\n' "$out_a" >&2
    exit 1
fi
for id in p2 p3 rust-git; do
    if grep -Fq "toolchain: $id " <<<"$out_a"; then
        printf 'A: false toolchain finding for %s (edge exists / comment only / the toolchain itself):\n%s\n' \
            "$id" "$out_a" >&2
        exit 1
    fi
done

# With the edge declared the finding must disappear, and the exit status must
# treat a finding exactly like every other audit finding (report-only: the
# audit exits 0 either way — findings never changed its exit status).
set_topology_record "$dir_a" p1 git 'rust-git'
run_builder fish "$dir_a/build-all.fish" --audit
out_a2=$FIXTURE_OUTPUT
rc_a2=$FIXTURE_RC
if [[ $rc_a2 -ne 0 ]]; then
    printf 'A: --audit failed after the edge was declared (rc=%d):\n%s\n' "$rc_a2" "$out_a2" >&2
    exit 1
fi
if grep -Fq 'toolchain:' <<<"$out_a2"; then
    printf 'A: toolchain finding survived the rust-git edge:\n%s\n' "$out_a2" >&2
    exit 1
fi
if [[ $rc_a2 -ne $rc_a ]]; then
    printf 'A: a finding changed the --audit exit status (%d -> %d); findings must\n' "$rc_a" "$rc_a2" >&2
    printf 'be reflected in it the same way existing findings are (they are not):\n%s\n' "$out_a" >&2
    exit 1
fi

# ─── B. ABI-batch refusal: llvm-git without rust-git ─────────────────────────
dir_b="$fixture/refusal"
make_workspace "$dir_b" 1 2 low
add_meta_package "$dir_b" llvm-git ''
add_meta_package "$dir_b" rust-git ''
add_meta_package "$dir_b" q1 ''
# The batch data the generic gate acts on: llvm-git is the anchor (abi=must,
# no abi-tagged dependency), rust-git is its mandatory member (abi=must plus
# the llvm-git edge).
set_topology_record "$dir_b" llvm-git git '' 'abi=must'
set_topology_record "$dir_b" rust-git git 'llvm-git' 'abi=must'
stub_sudo "$dir_b"

# The stub pacman reports rust-git as INSTALLED — the refusal's precondition.
# -Qp/-Qi answer nothing, so the -i same-version check stays conservative.
# Arguments arrive `pacman -Q -- NAME` since the gate's keyed abi_id_installed
# landed — `--` is stripped before the name is read (section G's convention).
cat >"$dir_b/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'pacman %s\n' "$*" >>"${GSA_FAKE_PACMAN_LOG:?}"
args=()
for a in "$@"; do
    [[ $a == -- ]] && continue
    args+=("$a")
done
case ${args[0]:-} in
-Q)
    [[ ${args[1]:-} == rust-git ]] && exit 0
    exit 1
    ;;
-Qp | -Qi) exit 1 ;;
esac
exit 0
EOF
chmod +x "$dir_b/bin/pacman"

cat >"$dir_b/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
id=$(basename "$PWD")
printf 'BUILD %s\n' "$id" >>"${GSA_FAKE_MAKEPKG_LOG:?}"
: >"$PWD/$id-1.0.0-1-any.pkg.tar.zst"
exit 0
EOF
chmod +x "$dir_b/bin/makepkg"

run_env_b() {
    run_builder env \
        PATH="$dir_b/bin:$PATH" \
        GSA_STATE_DIR="$dir_b/state" \
        GSA_FAKE_PACMAN_LOG="$dir_b/pacman.log" \
        GSA_FAKE_MAKEPKG_LOG="$dir_b/makepkg.log" \
        GSA_CPU_THREADS=8 \
        GSA_MEMORY_GIB=16 \
        fish "$dir_b/build-all.fish" "$@"
}

# B1: the real build must be refused before anything is built. A bare
# llvm-git can no longer reach this gate — consumer expansion pulls in its
# batch partner rust-git automatically (that is the feature; the direction is
# pinned in D below) — so the refusal is re-pinned on --no-deps llvm-git: the
# leaf-only selection that names the anchor WITHOUT its mandatory member. The
# gate itself is an unchanged backstop: same message, nothing built.
run_env_b --no-deps llvm-git
if [[ $FIXTURE_RC -eq 0 ]]; then
    printf 'B1: llvm-git WITHOUT rust-git was allowed to build:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
for want in \
    'refusing to build llvm-git without rust-git' \
    'abi=must batch anchor' \
    'rebuild in the same selection' \
    'rebuild rust-git in the same run' \
    'check_rustc_sanity recovery text'; do
    if ! grep -Fq "$want" <<<"$FIXTURE_OUTPUT"; then
        printf 'B1: refusal message is missing %q:\n%s\n' "$want" "$FIXTURE_OUTPUT" >&2
        exit 1
    fi
done
if [[ -s "$dir_b/makepkg.log" ]]; then
    printf 'B1: the refusal came after builds were dispatched:\n%s\n' \
        "$(cat "$dir_b/makepkg.log")" >&2
    exit 1
fi

# B2: the negative — rust-git in the selection must NOT be refused.
run_env_b --allow-broken-rustc llvm-git rust-git
if [[ $FIXTURE_RC -ne 0 ]]; then
    printf 'B2: a selection that rebuilds rust-git was refused:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
if ! grep -Fq 'All builds succeeded!' <<<"$FIXTURE_OUTPUT"; then
    printf 'B2: llvm-git + rust-git did not build:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
if ! grep -Fq 'BUILD llvm-git' "$dir_b/makepkg.log" ||
    ! grep -Fq 'BUILD rust-git' "$dir_b/makepkg.log"; then
    printf 'B2: not both packages reached the stub makepkg:\n%s\n' \
        "$(cat "$dir_b/makepkg.log")" >&2
    exit 1
fi

# B3/B4: the read-only modes on the SAME llvm-without-rust selection must be
# unaffected — they build nothing and the refusal gates real builds only.
run_env_b --no-deps -n llvm-git
if [[ $FIXTURE_RC -ne 0 ]] || ! grep -Fq 'Build order (dry run)' <<<"$FIXTURE_OUTPUT"; then
    printf 'B3: -n on the refused selection failed:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
run_env_b --no-deps -l llvm-git
if [[ $FIXTURE_RC -ne 0 ]]; then
    printf 'B4: -l on the refused selection failed:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi

# ─── C. dispatcher: mid-run probe after the run's own llvm install ──────────
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

# ─── D. repo policy: the committed topology orders and tags the batch ───────
# The 2026-09-25 dispatch order let mold-git (a cargo recipe) build before
# rust-git because its edge record was empty. Read-only against the committed
# topology, through the builder's --topology data channel (vulkan-pair's
# style) — every record is id|path|groups|edges|tags, so field 4 is the edge
# list and field 5 the batch tags.
topo_out="$fixture/topology.txt"
if ! fish "$root/build-all.fish" --topology >"$topo_out" 2>"$fixture/topology.err"; then
    fail "D: --topology failed on the committed config: $(cat "$fixture/topology.err")"
fi
mold_line=$(awk -F'|' '$1 == "mold-git"' "$topo_out")
if [[ -z $mold_line ]]; then
    fail "D: no mold-git record in the --topology output"
fi
mold_edges=$(awk -F'|' '$1 == "mold-git" { print $4 }' "$topo_out")
if ! tr ',' '\n' <<<"$mold_edges" | grep -qx 'rust-git'; then
    fail "D: mold-git declares no rust-git edge (got: $mold_edges)"
fi

# Batch membership is data now, not prose: llvm-git is the anchor and
# rust-git its mandatory member — both must carry the abi=must tag.
for id in llvm-git rust-git; do
    tags=$(awk -F'|' -v id="$id" '$1 == id { print $5 }' "$topo_out")
    if ! tr ',' '\n' <<<"$tags" | grep -qx 'abi=must'; then
        fail "D: $id is not tagged abi=must in the committed topology (got: $tags)"
    fi
done

# The batch must actually order a bare-name selection in CONSUMER direction:
# selecting X pulls X's transitive consumers, X first. rust-git consumes
# llvm-git (its edge is the batch's member->anchor direction), so bare
# llvm-git pulls rust-git in and llvm-git builds BEFORE it. The pair runs on
# B1's synthetic topology — where the batch is exactly these two — because
# the committed tree's llvm-git carries more consumers than the pair.
run_env_b -n llvm-git
if [[ $FIXTURE_RC -ne 0 ]]; then
    printf 'D: dry run of bare llvm-git failed:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
idx_of() { # $1 = package id; prints its 1-based order index or nothing
    awk -v pkg="$1" '$2 == pkg { sub(/\.$/, "", $1); print $1 }' \
        <<<"$FIXTURE_OUTPUT" | head -1
}
rust_idx=$(idx_of rust-git)
llvm_idx=$(idx_of llvm-git)
if [[ -z ${rust_idx:-} || -z ${llvm_idx:-} ]]; then
    printf 'D: a bare llvm-git selection does not expand to its consumer rust-git:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
if ((llvm_idx >= rust_idx)); then
    printf 'D: llvm-git (index %s) does not build before its consumer rust-git (index %s):\n%s\n' \
        "$llvm_idx" "$rust_idx" "$FIXTURE_OUTPUT" >&2
    exit 1
fi

# ─── E. Non-ABI tags keep the severity result at `none` ─────────────────────
# _TAGS carries app-cluster tags as well as ABI tags. A cluster-only record is
# valid and must not produce an empty package_abi_severity result during the
# real-build ABI gate. The combined record below pins that its ABI severity is
# still used when an app-cluster tag is also present.
dir_e="$fixture/non-abi-tags"
make_workspace "$dir_e" 1 2 low
make_install_conf "$dir_e/pacman.conf" # the -i run's IgnorePkg registration target (never the host's)
add_meta_package "$dir_e" llvm-git ''
add_meta_package "$dir_e" fcitx5-git ''
add_meta_package "$dir_e" fcitx5-qt-git ''
add_meta_package "$dir_e" untagged-app ''
add_meta_package "$dir_e" versioned-app ''
set_topology_record "$dir_e" llvm-git core '' 'abi=must'
set_topology_record "$dir_e" fcitx5-git app '' 'app-cluster=fcitx5'
set_topology_record "$dir_e" fcitx5-qt-git app 'llvm-git' 'abi=should,app-cluster=fcitx5'
set_topology_record "$dir_e" untagged-app app ''
set_topology_record "$dir_e" versioned-app app '' 'version-sync=nvchecker'
stub_sudo "$dir_e"
stub_pacman "$dir_e"
stub_makepkg "$dir_e"
# Hermetic probe subject: section E runs -i, so the mid-run sanity probe
# re-runs after llvm-git's lane. It must not depend on the HOST's rustc — a
# machine in the exact broken state the guard exists for would fail this
# unrelated subject (and does). A trivially working stub keeps E about
# non-ABI tags; the probe's own behaviour is pinned in section C and in
# tests/toolchain-remediation.sh.
cat >"$dir_e/bin/rustc" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$dir_e/bin/rustc"

run_env_e() {
    run_builder env \
        PATH="$dir_e/bin:$PATH" \
        GSA_STATE_DIR="$dir_e/state" \
        _IGNOREPKG_CONF="$dir_e/pacman.conf" \
        GSA_FAKE_PACMAN_LOG="$dir_e/pacman.log" \
        GSA_CPU_THREADS=8 \
        GSA_MEMORY_GIB=16 \
        fish "$dir_e/build-all.fish" "$@"
}

# The ABI member stays outside the --no-deps selection, so the installed
# abi=should candidate is reported. The cluster-only, version-sync-only and
# untagged records must be treated as severity `none` at the same gate.
run_env_e --no-deps -i --no-sync --allow-broken-rustc \
    llvm-git fcitx5-git untagged-app versioned-app
if [[ $FIXTURE_RC -ne 0 ]]; then
    printf 'E: real build with a cluster-only tag failed (rc=%d):\n%s\n' \
        "$FIXTURE_RC" "$FIXTURE_OUTPUT" >&2
    exit 1
fi
if grep -Fq 'test: Missing argument at index 3' <<<"$FIXTURE_OUTPUT"; then
    printf 'E: non-ABI tags produced an empty ABI severity:\n%s\n' \
        "$FIXTURE_OUTPUT" >&2
    exit 1
fi
if ! grep -Fq 'same-pass candidates not in this selection: fcitx5-qt-git' \
    <<<"$FIXTURE_OUTPUT"; then
    printf 'E: combined app-cluster/abi=should member was not preserved as a candidate:\n%s\n' \
        "$FIXTURE_OUTPUT" >&2
    exit 1
fi
if [[ $(rr_scalar outcome <<<"$FIXTURE_OUTPUT") != success ]]; then
    printf 'E: run record did not report success:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
for pkg in llvm-git fcitx5-git untagged-app versioned-app; do
    if [[ $(rr_row "$pkg" status <<<"$FIXTURE_OUTPUT") != succeeded ]]; then
        printf 'E: selected package %s did not succeed:\n%s\n' \
            "$pkg" "$FIXTURE_OUTPUT" >&2
        exit 1
    fi
done

# ─── F. grouping policy: hub/toolchain membership in the topology records ───
# docs/MEMORY.md §1 rule 21 membership tests, one pin per sub-check:
#   a. the compile-toolchain set carries BOTH core and build-tools;
#   b. a package with ≥2 edge-consumers (a record listing X in edges consumes
#      X) carries core, except the rule 21(a) app-cluster exception in F(b)
#      below;
#   c. ripgrep and fd declare a rust-git edge (rule 21(e) — the toolchain-edge
#      discipline the builder's --audit lint checks);
#   d. every group named in a record is one of the six roster names, and
#      build-tools is always dual with core.
# The checks read the topology RECORDS themselves — the raw
# id|path|groups|edges[|tags] lines of ${1:-$root/config/topology.conf} — so
# each assertion below owns its own failure message and the optional $1 lets
# a falsification run point them at a scratch copy with one flipped record
# (the repo config is never written). D reads the builder's normalized
# --topology view; F deliberately reads the two record fields the policy
# names: groups and edges.
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
# (this is the gap --audit flags; D pins mold-git's edge through --topology).
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

# ─── G. layer 2: soname drift drags the consumer closure into the batch ────
# The ABI-drift guard's batch half (build-all.fish, `ABI-drift guard layer
# 2`): a provider whose soname-provides set (committed .SRCINFO bare stems)
# differs from the installed stock package's provides must rebuild its FULL
# in-tree consumer closure in the same selection. Pure gate logic — nothing
# is dispatched before it decides — and it REFUSES (never silently expands)
# an installed closure member left out of the selection. The consumer
# relation is pinned in both halves here: a topology edge and a .SRCINFO
# depend on the provider's soname provide.
dir_g="$fixture/abi-drift"
make_workspace "$dir_g" 1 2 low
add_meta_package "$dir_g" libs-git ''
add_meta_package "$dir_g" app-git ''
set_topology_record "$dir_g" app-git git 'libs-git'
{
    printf 'pkgbase = libs-git\n'
    printf 'pkgname = libs-git\n'
    printf '\tprovides = libgreet.so\n'
} >"$dir_g/packages/libs-git/.SRCINFO"
{
    printf 'pkgbase = app-git\n'
    printf 'pkgname = app-git\n'
    printf '\tdepends = libgreet.so\n'
} >"$dir_g/packages/app-git/.SRCINFO"
stub_sudo "$dir_g"

# The stub makepkg: B's shape — a BUILD marker plus the trivial archive.
cat >"$dir_g/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
id=$(basename "$PWD")
printf 'BUILD %s\n' "$id" >>"${GSA_FAKE_MAKEPKG_LOG:?}"
: >"$PWD/$id-1.0.0-1-any.pkg.tar.zst"
exit 0
EOF
chmod +x "$dir_g/bin/makepkg"

# The stub pacman: arguments arrive `pacman -Q -- NAME` / `pacman -Qi -- NAME`
# (the builder passes `--` before names), so `--` is dropped before reading.
# `-Qi libs` answers the INSTALLED STOCK surface from GSA_FAKE_QI_LIBS
# (changed: `libold.so=1-64` against the house `libgreet.so`; unchanged:
# `libgreet.so=1-64` — the auto-versioned form of the same bare stem, so the
# STEM sets compare equal), and `-Q app-git` answers closure-member
# membership from GSA_FAKE_APP_INSTALLED. Everything else is not installed.
cat >"$dir_g/bin/pacman" <<'EOF'
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
    if [[ ${args[1]:-} == libs && -n ${GSA_FAKE_QI_LIBS:-} ]]; then
        printf '%s\n' "$GSA_FAKE_QI_LIBS"
        exit 0
    fi
    exit 1
    ;;
-Q)
    if [[ ${args[1]:-} == app-git ]]; then
        [[ ${GSA_FAKE_APP_INSTALLED:-0} == 1 ]] && exit 0
    fi
    exit 1
    ;;
esac
exit 1
EOF
chmod +x "$dir_g/bin/pacman"

run_env_g() {
    run_builder env \
        PATH="$dir_g/bin:$PATH" \
        GSA_STATE_DIR="$dir_g/state" \
        GSA_FAKE_PACMAN_LOG="$dir_g/pacman.log" \
        GSA_FAKE_MAKEPKG_LOG="$dir_g/makepkg.log" \
        GSA_FAKE_QI_LIBS="$GSA_FAKE_QI_LIBS" \
        GSA_FAKE_APP_INSTALLED="$GSA_FAKE_APP_INSTALLED" \
        GSA_CPU_THREADS=8 \
        GSA_MEMORY_GIB=16 \
        fish "$dir_g/build-all.fish" "$@"
}

qi_changed='Name : libs
Version : 1-1
Provides : libold.so=1-64'
qi_unchanged='Name : libs
Version : 1-1
Provides : libgreet.so=1-64'

# G1: changed surface + INSTALLED consumer omitted via --no-deps ⇒ the batch
# refuses before anything is built, naming provider, reason and missing
# member.
GSA_FAKE_QI_LIBS=$qi_changed
GSA_FAKE_APP_INSTALLED=1
: >"$dir_g/makepkg.log"
run_env_g --no-deps --no-sync --allow-broken-rustc libs-git
if [[ $FIXTURE_RC -eq 0 ]]; then
    printf 'G1: a drifted surface with an omitted installed consumer built:\n%s\n' \
        "$FIXTURE_OUTPUT" >&2
    exit 1
fi
for want in \
    'refusing to build libs-git without app-git' \
    'soname provides changed' \
    'missing: app-git'; do
    if ! grep -Fq "$want" <<<"$FIXTURE_OUTPUT"; then
        printf 'G1: refusal message is missing %q:\n%s\n' "$want" "$FIXTURE_OUTPUT" >&2
        exit 1
    fi
done
if [[ -s "$dir_g/makepkg.log" ]]; then
    printf 'G1: the refusal came after builds were dispatched:\n%s\n' \
        "$(cat "$dir_g/makepkg.log")" >&2
    exit 1
fi

# G2: the closure rebuilt in the same selection ⇒ clean batch, both build.
: >"$dir_g/makepkg.log"
run_env_g --no-deps --no-sync --allow-broken-rustc libs-git app-git
if [[ $FIXTURE_RC -ne 0 ]] || ! grep -Fq 'All builds succeeded!' <<<"$FIXTURE_OUTPUT"; then
    printf 'G2: the complete closure was refused or failed:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
if ! grep -Fq 'BUILD libs-git' "$dir_g/makepkg.log" ||
    ! grep -Fq 'BUILD app-git' "$dir_g/makepkg.log"; then
    printf 'G2: not both packages reached the stub makepkg:\n%s\n' \
        "$(cat "$dir_g/makepkg.log")" >&2
    exit 1
fi

# G3: unchanged surface ⇒ no drift, no batch tightening: the provider builds
# alone even with the consumer installed and omitted.
GSA_FAKE_QI_LIBS=$qi_unchanged
: >"$dir_g/makepkg.log"
run_env_g --no-deps --no-sync --allow-broken-rustc libs-git
if [[ $FIXTURE_RC -ne 0 ]] || grep -Fq 'refusing to build' <<<"$FIXTURE_OUTPUT"; then
    printf 'G3: an unchanged surface must not gate:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
if ! grep -Fq 'BUILD libs-git' "$dir_g/makepkg.log"; then
    printf 'G3: libs-git did not build:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi

# G4: drifted surface but the consumer is NOT installed ⇒ nothing to
# protect: the provider builds alone.
GSA_FAKE_QI_LIBS=$qi_changed
GSA_FAKE_APP_INSTALLED=0
: >"$dir_g/makepkg.log"
run_env_g --no-deps --no-sync --allow-broken-rustc libs-git
if [[ $FIXTURE_RC -ne 0 ]] || grep -Fq 'refusing to build' <<<"$FIXTURE_OUTPUT"; then
    printf 'G4: an uninstalled consumer must not gate:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
if ! grep -Fq 'BUILD libs-git' "$dir_g/makepkg.log"; then
    printf 'G4: libs-git did not build:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi

# ─── H. gate COST at synthetic scale: probe-count bounds ────────────────────
# The 2026-10-05 gate rewrite keyed/memoised every helper that forks pacman
# (abi_id_installed / abi_pkg_installed / abi_installed_provides) and turned
# the batch/closure walks into BFS over keyed adjacency. This section pins the
# COST of the gate the only non-flaky way a fixture has: PACMAN PROBE COUNTS
# against the stub's argv log — never wall-clock timing (it flakes on shared
# machines). The expensive shape for the old per-(anchor × member) probe is
# synthetic: 4 abi=must anchors sharing ONE pool of 240 installed abi=must
# members (960 anchor×member visits) and 3 soname-drift providers sharing the
# same 240 members as their layer-2 consumer closure (720 provider×member
# visits). The members' .SRCINFO depends name the providers' soname provides,
# so the closure is pinned in BOTH halves like section G (topology edge +
# name edge). Decisions are asserted unchanged on the way: B1's tag refusal,
# G1's layer-2 refusal (both with nothing dispatched), and a complete batch
# that builds all 244 of its packages.
(
    set -euo pipefail
    dir_h="$fixture/abi-gate-cost"
    make_workspace "$dir_h" 1 2 low

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
esac
exit 1
EOF
    chmod +x "$dir_h/bin/pacman"

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
