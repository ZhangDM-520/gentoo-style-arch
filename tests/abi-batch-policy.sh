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
# Four policy seams are pinned here, one section each:
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
#      check_rustc_sanity BEFORE anything else dispatches; a failing probe
#      stops dispatch, drains in-flight lanes and exits non-zero.
#   D. Repo policy: config/topology.conf declares mold-git's rust-git edge
#      (the missing edge that let a cargo recipe dispatch before rust-git),
#      a bare-name selection pulls its abi-coupled partner in build order
#      (llvm-git before its consumer rust-git), and the llvm-git /
#      rust-git batch membership is recorded as tags. Read through the
#      builder's --topology data channel — the same interface
#      tests/srcinfo-freshness.sh consumes.
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
# marker; p2's build compiles Rust and dies once the marker exists. The
# builder must stop dispatch BEFORE p2 is ever started.
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

printf 'abi-batch-policy fixture: PASS\n'
