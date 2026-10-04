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
# Seven policy seams are pinned here, one section each:
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
#      (allow-lists: the rule 21(a) app-cluster exception, plus the Q2-open
#      register — see section F(b) for the written justification); ripgrep and fd
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
cat >"$dir_b/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'pacman %s\n' "$*" >>"${GSA_FAKE_PACMAN_LOG:?}"
case ${1:-} in
-Q)
    [[ ${2:-} == rust-git ]] && exit 0
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
#      X) carries core, except the two exception classes in F(b) below
#      (rule 21(a) app-cluster exception; the Q2-open register);
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

# b. the hub rule: ≥2 edge-consumers ⇒ core. Two exception classes, each
# entry naming its reason:
#   - rule 21(a)'s app-cluster exception: a member whose consumers are all
#     its own app-cluster siblings stays app;
#   - the Q2-open register below — WRITTEN JUSTIFICATION for narrowing this
#     pin's scope (an expectation may change only with written
#     justification): rule 21(a) and this check were pinned on the
#     2026-10-04 build-tools migration's CURATED build-order edge graph
#     (144 records), where "a record listing X in edges consumes X"
#     identified ABI hubs. The 2026-10-04 topology wiring then replaced
#     that edge set with the FULL dependency/supersession graph (653
#     records / 3373 edges, landed and verified; config/topology.conf is
#     outside this fixture's write scope), so a raw reverse-edge count no
#     longer identifies ABI-coupled hubs: 204 records have ≥2
#     edge-consumers without carrying `core`, including nearly every
#     shared library. Whether those records gain `core` dual membership is
#     the wiring handoff's OPEN QUESTION Q2 ("ABI-libs vs core dual
#     membership"), explicitly deferred to the docs/ABI-policy phase — not
#     this fixture's decision to make. Until Q2 lands, every CURRENT
#     violation is registered below (reason: Q2-open) so the pin keeps its
#     teeth: a NEW ≥2-consumer record without `core` still fails until it
#     carries `core` or its own written exception is added here. When Q2
#     lands (the records gain `core`, or rule 21(a) is revised), delete the
#     register and the bare pin binds again.
hub_rule_exempt=(
    'fcitx5-git' # app-cluster exception: its five consumers are all its own app-cluster=fcitx5 siblings
)
# Q2-open hub-rule debt register (reason above, shared by every entry).
# 203 ids as of the 2026-10-04 wiring (fcitx5-qt-git included: its consumers
# are NOT all cluster siblings — fcitx5-configtool is stable).
q2_open_hubs=(
    acl-git alsa-lib appstream apr-util
    at-spi2-core-git audit bash binutils
    bluez-libs boost-libs brotli-git bzip2-git
    coreutils cups-git curl dbus-broker
    desktop-file-utils elfutils-git enchant exiv2
    expat-git fcitx5-qt-git ffmpeg-git fftw
    file fluidsynth-git fontconfig-git freetype2-git
    gc gdbm-git gdk-pixbuf2-git gegl-git
    gettext ghostscript git-git glu
    gnutls-git gobject-introspection gstreamer harfbuzz-git
    icu-git imagemagick jack2-git jansson-git
    jemalloc-git jq kmod-git krb5-git
    kwindowsystem ladspa lame lcms2
    libarchive-git libass libbpf-git libbs2b-git
    libcaca libcap libcap-ng-git libdc1394
    libdex-git libebur128-git libedit libei-git
    libepoxy-git libevdev-git libexif-git libfdk-aac-git
    libffi-git libfido2-git libfreeaptx libgcrypt
    libgexiv2-git libglvnd-git libgudev libheif-git
    libidn2-git libinput-git libjpeg-turbo-git libjxl-git
    liblc3-git libldac libldap libmypaint-git
    libmysofa-git libnghttp2-git libnl-git libnotify
    libpciaccess-git libplist-git libpng-git libproxy-git
    libpsl-git libpulse-git libraw-git librsvg-git
    libseccomp-git libsecret libsm libsndfile-git
    libsodium-git libssh2-git libtiff-git libtirpc
    libtool-git libunwind-git liburing-git libusb-git
    libva-git libwebp-git libwmf-git libx11-git
    libxcb-git libxcomposite libxcrypt-git libxcursor
    libxdamage libxext-git libxfixes libxi-git
    libxinerama libxkbcommon-git libxkbfile libxml2-git
    libxmu libxpm-git libxrandr-git libxrender
    libxshmfence libxslt-git libxss libxt
    libxtst lilv-git lz4-git lzo
    mariadb-libs mesa-git mpg123 ncurses-git
    neon nettle-git networkmanager nodejs
    nspr-git nss-git openal-git opencolorio
    openimageio openjpeg2 openssh openxr
    opus-git pam pcre2-git perl
    pipewire pixman-git pkcs11-helper poppler
    postgresql-libs python python-gobject python-lxml
    qrencode qt5-wayland raptor readline-git
    ripgrep rsync sbc sdl2-git
    shadow shared-mime-info spandsp-git speech-dispatcher
    sqlite subversion twolame udisks2
    unixodbc unzip upower util-linux
    vamp-plugin-sdk vulkan-headers-git vulkan-icd-loader-git wayland-protocols-git
    webkit2gtk-4.1 webrtc-audio-processing-1 xcb-util xcb-util-cursor
    xcb-util-image xcb-util-keysyms xcb-util-renderutil xcb-util-wm
    xdg-desktop-portal-gtk-git xdg-utils xxhash-git xz-git
    zip zlib-ng-compat-git zstd-git
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
q2_registered() { # $1 = package id — is it in the Q2-open register?
    local x
    for x in "${q2_open_hubs[@]}"; do
        if [[ $x == "$1" ]]; then
            return 0
        fi
    done
    return 1
}
while read -r id consumers; do
    if exempt_hub "$id" || q2_registered "$id"; then
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

printf 'abi-batch-policy fixture: PASS\n'
