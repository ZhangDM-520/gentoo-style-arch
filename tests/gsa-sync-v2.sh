#!/usr/bin/env bash
set -euo pipefail

# tests/gsa-sync-v2.sh — the VERSION-SYNC surface, the skip claims and the
# toolchain preflight of the NATIVE engine (docs/gsa-contract.md §B.4/§B.8,
# rule 18 anchoring). Everything here is synthetic: $TMPDIR workspaces whose
# recipes live at the physical `packages/stable/` placement the Arch provider
# gates on, and `pacman`/`curl`/`updpkgsums`/`makepkg`/`rustc` stubs at the
# process boundary — no provider is queried over the network, no package is
# really built, nothing outside the fixture tree is written. Expectations
# come from the recipe bytes (pre-image diffs), the stub logs and the
# `format: 2` run record (rule 25(j) / contract §L.3) — never from prose
# alone.
#
# Pinned here (six ( subshell ) sections, one per scenario):
#   1. `gsa -Sy` happy path: the stubbed Arch provider reports a newer
#      version, the PKGBUILD is rewritten (pkgver/pkgrel) and RULE-18
#      re-anchors the checksums to the provider's published digest over the
#      MOVED source, the run-level disposition block prints on stdout, rc 0,
#      and the rewrite is left UNCOMMITTED (differs from the pre-image copy —
#      `git diff` is the maintainer's disposition).
#   2. provider outage during `-Sy` is a DEFERRAL, never an invented version:
#      (a) a query outage (`pacman -Si` failure) defers upstream-unverified
#      before any write; (b) an anchoring-time outage (curl failure after the
#      rewrite) defers anchoring-refused and RESTORES the recipe
#      byte-identically. Both rc 5 with the deferral notes on stderr.
#   3. a published checksum disagreement is an integrity stop: rc 3,
#      `refusing to rewrite — integrity-stop` / `restored byte-for-byte` on
#      stderr, recipe byte-identical (the updpkgsums rewrite is rolled back
#      with the version rewrite).
#   4. `gsa -Su`: the sync moves a version → the stale set is exactly that
#      recipe → the run builds (stub makepkg) + installs (stub pacman) and
#      the run record covers it; a re-run with nothing stale is
#      `- noop empty-list` / `- succeeded 0 - empty-list`, rc 0; `-Su
#      --dry-run` renders the plan record (build-install + never-started
#      dry-run rows) while never querying, never rewriting and never
#      building.
#   5. skip claims on a build run: `--skip` claims a fresh prebuilt set as
#      plan `skip ok` / outcome `succeeded - - ok` with ZERO makepkg
#      invocations; `--skip-built` claims as `skip skip-built`; `--no-sync`
#      proves NO provider query happens (the `pacman -Si` log stays empty,
#      with a without-flag control run that fills it — the log works).
#   6. toolchain preflight: `pacman -Q rust-git` installed + a broken `rustc`
#      refuses before dispatch (rc 3, every row `never-started - -
#      preflight-refused`, no build), and `--allow-broken-rustc` proceeds to
#      build.
#
# Complement to tests/anchor-defer.sh (do not duplicate): that fixture drives
# a BUILD run's pre-dispatch deferral through a makepkg rc 99 and pins the
# parked cone + resume set; nothing there exercises `-Sy`/`-Su`, checksum
# anchoring, the skip claims or the rustc probe, and nothing here re-tests
# cone parking.
#
# House conventions: `( subshell )` sections (each an isolated scenario with
# its own workspace), inline oracle stubs (§D.2), `fail()` prefixes, and
# tests/lib/rr-v2.bash's `format: 2` parser + run_engine. Two deliberate
# deviations, both precedented: the `-Sy` sections invoke the engine DIRECTLY
# through the §B.10 privileged wrapper (`/usr/bin/sudo -n env …`, see run_sy)
# with stdout/stderr captured separately (its contract is stream-split — the
# disposition block on stdout, policy notes on stderr — while run_engine
# merges), and the two §B.4 budget-less records (`-Su`'s empty-stale noop
# record and a `--dry-run` plan record render `lanes: -`) are asserted from
# the raw block, because rr2_*'s strict scalar grammar rejects a non-integer
# budget by design (the tests/gsa-install-v2.sh precedent says so too).

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"

fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-sync-v2.XXXXXX")
# Root-safe cleanup: the engine writes its state tree as root (W5), so the
# plain rm would leave Permission denied noise even on a passing run.
trap '/usr/bin/sudo -n rm -rf -- "$fixture" 2>/dev/null || rm -rf -- "$fixture" 2>/dev/null || true' EXIT

fail() {
    printf '%s\n' "$1" >&2
    if [ -n "${2:-}" ] && [ -f "$2" ]; then
        sed 's/^/    /' "$2" >&2
    fi
    exit 1
}

# ─── Stub-knob vocabulary (§D.2: declared here in the change that adds them) ─
rr2_stub_knob GSA_FAKE_SYNC_SI_MODE "gsa-sync-v2 pacman stub: pacman -Si scenario (found|outage|unknown)"
rr2_stub_knob GSA_FAKE_SYNC_SI_VERSION "gsa-sync-v2 pacman stub: Version string the found scenario answers"
rr2_stub_knob GSA_FAKE_SYNC_SI_LOG "gsa-sync-v2 pacman stub: provider-query (pacman -Si) log"
rr2_stub_knob GSA_FAKE_SYNC_PACMAN_LOG "gsa-sync-v2 pacman stub: full argv log"
rr2_stub_knob GSA_FAKE_SYNC_RUSTGIT "gsa-sync-v2 pacman stub: pacman -Q rust-git answer (installed|absent)"
rr2_stub_knob GSA_FAKE_SYNC_CURL_MODE "gsa-sync-v2 curl stub: provider metadata scenario (ok|outage)"
rr2_stub_knob GSA_FAKE_SYNC_SRCINFO "gsa-sync-v2 curl stub: canned official .SRCINFO to serve"
rr2_stub_knob GSA_FAKE_SYNC_PAYLOAD "gsa-sync-v2 updpkgsums stub: bytes staged as the fetched source"
rr2_stub_knob GSA_FAKE_SYNC_STAGED_NAME "gsa-sync-v2 updpkgsums stub: makepkg source name of the staged file"
rr2_stub_knob GSA_FAKE_SYNC_MAKEPKG_LOG "gsa-sync-v2 makepkg stub: invocation log"

# ─── The engine under test: built into the fixture tree (scratch only) ──────
# GSA_TEST_GSA_BIN, when already set to an executable, is that engine (the
# rr-v2.bash run_engine convention) and the scratch build is skipped.
if [ -z "${GSA_TEST_GSA_BIN:-}" ]; then
    cargo build --offline --quiet --target-dir "$fixture/cargo" -p gsa-cli \
        --manifest-path "$gsa_repo_root/Cargo.toml" \
        || fail "cannot build the gsa binary for the fixture"
    GSA_TEST_GSA_BIN="$fixture/cargo/debug/gsa"
fi
[ -x "$GSA_TEST_GSA_BIN" ] || fail "the engine under test is not executable: $GSA_TEST_GSA_BIN"
export GSA_TEST_ENGINE=gsa
export GSA_TEST_GSA_BIN

# ─── Workspace/stub synthesis (oracle-shaped inline: §D.2 keeps the meaning
# in the fixture that asserts it) ────────────────────────────────────────────

# stable_recipe WS ID — one Arch-provider recipe PHYSICALLY under
# packages/stable (the placement gate sync_arch enforces), its source URL
# tracking $pkgver so a version move MOVES the expanded source and rule-18
# anchoring engages, plus its topology record. The physical path is
# fixture-owned: tests/lib/fixture-lib.bash's add_package/set_topology_record
# hard-code packages/<id>, which the Arch provider never syncs.
stable_recipe() {
    local ws=$1 id=$2
    local dir="$ws/packages/stable/$id"
    mkdir -p "$dir"
    {
        printf 'pkgname=%s\n' "$id"
        printf 'pkgver=1.0.0\n'
        printf 'pkgrel=1\n'
        printf 'arch=(any)\n'
        printf 'source=("%s-$pkgver.tar.gz::https://example.invalid/%s-$pkgver.tar.gz")\n' "$id" "$id"
        printf "sha256sums=('0000000000000000000000000000000000000000000000000000000000000000')\n"
    } >"$dir/PKGBUILD"
    printf '%s|packages/stable/%s|stable|\n' "$id" "$id" >>"$ws/config/topology.conf"
}

# provider_srcinfo FILE ID PKGVER SUM — the canned official packaging-repo
# .SRCINFO the curl stub serves: srcinfo_sum_map keys its checksums by the
# makepkg source name, which is exactly ArchOfficial::anchor_key's binding.
provider_srcinfo() {
    local file=$1 id=$2 ver=$3 sum=$4
    {
        printf 'pkgbase = %s\n' "$id"
        printf '\tpkgver = %s\n' "$ver"
        printf '\tpkgrel = 2\n'
        printf '\tpkgdesc = fixture\n'
        printf '\tarch = any\n'
        printf 'source = %s-%s.tar.gz::https://example.invalid/%s-%s.tar.gz\n' "$id" "$ver" "$id" "$ver"
        printf 'sha256sums = %s\n' "$sum"
        printf 'pkgname = %s\n' "$id"
    } >"$file"
}

# write_stub_pacman DIR — the provider/payload/probe oracle: `pacman -Si`
# answers the version scenario and logs the QUERY (the --no-sync proof reads
# this log), `pacman -Q rust-git` gates the rustc probe, `pacman -Qp` blesses
# the payload gate, everything else (install transactions included) succeeds.
write_stub_pacman() {
    cat >"$1/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'pacman %s\n' "$*" >>"${GSA_FAKE_SYNC_PACMAN_LOG:?}"
case "${1:-}" in
-Si)
    printf 'query %s\n' "${2:-}" >>"${GSA_FAKE_SYNC_SI_LOG:?}"
    case "${GSA_FAKE_SYNC_SI_MODE:-unknown}" in
    found)
        printf 'Repository      : core\n'
        printf 'Name            : %s\n' "${2:-}"
        printf 'Version         : %s\n' "${GSA_FAKE_SYNC_SI_VERSION:?}"
        exit 0
        ;;
    outage)
        printf 'error: failed retrieving file "core.db" (fixture outage)\n' >&2
        exit 1
        ;;
    esac
    exit 0
    ;;
-Q)
    if [ "${2:-}" = rust-git ] && [ "${GSA_FAKE_SYNC_RUSTGIT:-absent}" = installed ]; then
        printf 'rust-git 1.0.0-1\n'
        exit 0
    fi
    exit 1
    ;;
esac
exit 0
EOF
    chmod +x "$1/bin/pacman"
}

# write_stub_curl DIR — the provider-metadata transport at the process
# boundary: serve the canned .SRCINFO with the trailing %{http_code}
# fetch_to_string splits off, or fail like a dead mirror.
write_stub_curl() {
    cat >"$1/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -u
if [ "${GSA_FAKE_SYNC_CURL_MODE:-ok}" = outage ]; then
    printf 'curl: (7) Failed to connect to fixture.invalid port 443\n' >&2
    exit 7
fi
cat "${GSA_FAKE_SYNC_SRCINFO:?}"
printf '200'
EOF
    chmod +x "$1/bin/curl"
}

# write_stub_updpkgsums DIR — makepkg's fetch+rewrite step at the process
# boundary (real updpkgsums is an in-place writer the sync snapshots first):
# stage the "fetched" source beside the recipe (locate_fetched's recipe-dir
# root) and rewrite the recipe's own sums to hash it. The PUBLISHED value the
# anchor grades against stays the curl stub's — a staged file can never
# become the anchor.
write_stub_updpkgsums() {
    cat >"$1/bin/updpkgsums" <<'EOF'
#!/usr/bin/env bash
set -u
cp "${GSA_FAKE_SYNC_PAYLOAD:?}" "$PWD/${GSA_FAKE_SYNC_STAGED_NAME:?}" || exit 1
sum=$(sha256sum "$PWD/${GSA_FAKE_SYNC_STAGED_NAME}") || exit 1
sum=${sum%% *}
sed -i "s/^sha256sums=.*/sha256sums=('$sum')/" "$PWD/PKGBUILD"
exit 0
EOF
    chmod +x "$1/bin/updpkgsums"
}

# write_stub_makepkg DIR — the build oracle: one argv log (the "was it built
# at all" proof), then one real .pkg.tar.zst shaped NAME-PV-PR-any from the
# recipe's own pkgver/pkgrel (discovery and the install decision read those).
write_stub_makepkg() {
    cat >"$1/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'makepkg %s\n' "$*" >>"${GSA_FAKE_SYNC_MAKEPKG_LOG:?}"
id=$(basename "$PWD")
pv=$(sed -n 's/^pkgver=//p' PKGBUILD | head -n1)
pr=$(sed -n 's/^pkgrel=//p' PKGBUILD | head -n1)
stage="$PWD/.stage-$id"
mkdir -p "$stage"
{
    printf 'pkgbase = %s\n' "$id"
    printf 'pkgname = %s\n' "$id"
    printf 'pkgver = %s-%s\n' "$pv" "$pr"
    printf 'arch = any\n'
} >"$stage/.PKGINFO"
tar --zstd -cf "$PWD/$id-$pv-$pr-any.pkg.tar.zst" -C "$stage" .PKGINFO
rm -rf "$stage"
exit 0
EOF
    chmod +x "$1/bin/makepkg"
}

# write_stub_rustc DIR — the broken toolchain the preflight must refuse on.
write_stub_rustc() {
    cat >"$1/bin/rustc" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'rustc: error: fixture LLVM ABI skew\n' >&2
exit 1
EOF
    chmod +x "$1/bin/rustc"
}

# write_stub_pacman_conf DIR DBROOT — `pacman-conf DBPath` answers the
# fixture's fabricated DB root for the install decision, never the host's.
write_stub_pacman_conf() {
    cat >"$1/bin/pacman-conf" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = DBPath ] && printf '%s\n' "$2"
exit 0
EOF
    chmod +x "$1/bin/pacman-conf"
}

# run_sy WS OUT ERR STATE — `gsa -Sy` with STREAMS SEPARATED (the pass's
# contract: the disposition block on stdout, policy/deferral notes on stderr)
# in the §B.10 privileged form: -Sy MUTATES, so it runs under the REAL
# /usr/bin/sudo (PATH may carry stub sudos) with the fixture env forwarded
# the way run_engine forwards it (sudo's env_reset would strip the stub PATH
# and every GSA_FAKE_* knob). STATE is the run's state root: the -Sy phase
# grammar DEFERS --state-dir to a later phase (rc 2, 2026-10-15), so the root
# rides GSA_STATE_DIR and no -Sy here can reach the live /var/lib/gsa. RC is
# returned in SY_RC; the engine always runs inside WS.
run_sy() {
    local ws=$1 state=$4
    local -a fwd=() env_args=()
    rr2_env_forward fwd
    local kv
    for kv in "${fwd[@]}"; do
        # the explicit GSA_STATE_DIR below must win over any ambient copy
        [[ $kv == GSA_STATE_DIR=* ]] && continue
        env_args+=("$kv")
    done
    env_args+=("GSA_STATE_DIR=$state")
    set +e
    ( cd "$ws" && /usr/bin/sudo -n env "${env_args[@]}" \
        "$GSA_TEST_GSA_BIN" -Sy ) >"$2" 2>"$3"
    SY_RC=$?
    set -e
}

# record_block FILE — the raw `format: 2` block of a capture. For the two
# §B.4 budget-less shapes only (`lanes: -` fails rr2_'s strict scalar
# grammar); every budgeted record goes through rr2_*.
record_block() {
    sed -n '/^--- run record begin ---$/,/^--- run record end ---$/p' "$1"
}

# ─── 1. -Sy happy path: rewrite + rule-18 anchoring, left uncommitted ──────
(
    set -euo pipefail
    ws="$fixture/s1/ws"
    make_workspace "$ws" 1 1 low
    stable_recipe "$ws" demo
    write_stub_pacman "$ws"
    write_stub_curl "$ws"
    write_stub_updpkgsums "$ws"
    write_stub_makepkg "$ws"
    export PATH="$ws/bin:$PATH"
    export GSA_FAKE_SYNC_PACMAN_LOG="$fixture/s1/pacman.log"
    export GSA_FAKE_SYNC_SI_LOG="$fixture/s1/si.log"
    export GSA_FAKE_SYNC_SI_MODE=found
    export GSA_FAKE_SYNC_SI_VERSION=2.0.0-2
    export GSA_FAKE_SYNC_CURL_MODE=ok
    export GSA_FAKE_SYNC_MAKEPKG_LOG="$fixture/s1/makepkg.log"
    export GSA_FAKE_SYNC_PAYLOAD="$fixture/s1/payload"
    export GSA_FAKE_SYNC_STAGED_NAME=demo-2.0.0.tar.gz
    printf 'demo payload for 2.0.0\n' >"$GSA_FAKE_SYNC_PAYLOAD"
    digest=$(sha256sum "$GSA_FAKE_SYNC_PAYLOAD")
    digest=${digest%% *}
    export GSA_FAKE_SYNC_SRCINFO="$fixture/s1/provider.SRCINFO"
    provider_srcinfo "$GSA_FAKE_SYNC_SRCINFO" demo 2.0.0 "$digest"

    recipe="$ws/packages/stable/demo"
    cp "$recipe/PKGBUILD" "$fixture/s1/PKGBUILD.pre"
    run_sy "$ws" "$fixture/s1/out" "$fixture/s1/err" "$fixture/s1/state"

    [ "$SY_RC" = 0 ] \
        || fail "-Sy happy path rc=$SY_RC, want 0:" "$fixture/s1/err"

    # the run-level disposition block (rule 18's maintainer deliverable)
    grep -F "Version and checksum sync this run (uncommitted — review with 'git diff', then commit):" \
        "$fixture/s1/out" >/dev/null \
        || fail "the disposition block is missing:" "$fixture/s1/out"
    grep -F 'demo: 1.0.0-1 → 2.0.0-2 (synced with Arch repo)' "$fixture/s1/out" >/dev/null \
        || fail "the version-sync disposition row is missing/wrong:" "$fixture/s1/out"
    grep -F 'demo: checksums re-anchored to the official demo 2.0.0' "$fixture/s1/out" >/dev/null \
        || fail "the checksum disposition row does not claim an anchor:" "$fixture/s1/out"
    if grep -F 'refresh-only' "$fixture/s1/out" >/dev/null; then
        fail "an anchored entry was reported refresh-only:" "$fixture/s1/out"
    fi
    # the anchoring log line (stderr): verified against the FETCHED bytes.
    # The authority wording of this PROSE line is not pinned (§L.3): the
    # engine renders it as "the provider demo" — classify_sync passes a
    # hardcoded owner label to AnchorOutcome::log_lines and drops the
    # report's own owner-labelled log (reported as an engine observation).
    # The authority is pinned from the disposition BLOCK above, which is data.
    grep -F 'checksums re-anchored to' "$fixture/s1/err" >/dev/null \
        || fail "the anchoring note is missing:" "$fixture/s1/err"
    grep -F 'checksums, and verified against the fetched sources' \
        "$fixture/s1/err" >/dev/null \
        || fail "the anchoring verification note is missing:" "$fixture/s1/err"
    # -Sy is the rewrite pass itself: disposition block, NEVER a run record
    if grep -F -- '--- run record begin ---' "$fixture/s1/out" >/dev/null; then
        fail "-Sy must not emit a run record:" "$fixture/s1/out"
    fi

    # the rewrite: pkgver/pkgrel moved and the sums carry the PUBLISHED
    # digest (the staged source hashes to it — a real anchor, not a fetch hash
    # echo: the pre-image placeholder differs)
    grep -Fx 'pkgver=2.0.0' "$recipe/PKGBUILD" >/dev/null \
        || fail "pkgver was not rewritten to 2.0.0:" "$recipe/PKGBUILD"
    grep -Fx 'pkgrel=2' "$recipe/PKGBUILD" >/dev/null \
        || fail "pkgrel was not rewritten to the provider's release:" "$recipe/PKGBUILD"
    grep -F "sha256sums=('$digest')" "$recipe/PKGBUILD" >/dev/null \
        || fail "the checksums were not re-anchored to the published digest:" "$recipe/PKGBUILD"
    [ -f "$recipe/demo-2.0.0.tar.gz" ] \
        || fail "the MOVED source was never staged for anchoring"
    # left UNCOMMITTED: the working tree carries the rewrite as a diff
    # against the pre-image copy; a run never commits
    if cmp -s "$fixture/s1/PKGBUILD.pre" "$recipe/PKGBUILD"; then
        fail "the recipe equals its pre-image — the rewrite is missing"
    fi
    # the sync pass itself never builds
    [ ! -s "$GSA_FAKE_SYNC_MAKEPKG_LOG" ] \
        || fail "-Sy invoked makepkg (it must only rewrite):" "$GSA_FAKE_SYNC_MAKEPKG_LOG"
)

# ─── 2. provider outage defers and restores — never invents a version ──────
(
    set -euo pipefail
    # 2a — the QUERY is down: nothing is ever written (the query precedes the
    # transaction), the committed version's freshness stays unverified.
    ws="$fixture/s2a/ws"
    make_workspace "$ws" 1 1 low
    stable_recipe "$ws" demo
    write_stub_pacman "$ws"
    write_stub_curl "$ws"
    write_stub_updpkgsums "$ws"
    write_stub_makepkg "$ws"
    export PATH="$ws/bin:$PATH"
    export GSA_FAKE_SYNC_PACMAN_LOG="$fixture/s2a/pacman.log"
    export GSA_FAKE_SYNC_SI_LOG="$fixture/s2a/si.log"
    export GSA_FAKE_SYNC_SI_MODE=outage
    export GSA_FAKE_SYNC_CURL_MODE=ok
    export GSA_FAKE_SYNC_MAKEPKG_LOG="$fixture/s2a/makepkg.log"
    export GSA_FAKE_SYNC_PAYLOAD="$fixture/s2a/payload"
    export GSA_FAKE_SYNC_STAGED_NAME=demo-2.0.0.tar.gz
    export GSA_FAKE_SYNC_SRCINFO="$fixture/s2a/provider.SRCINFO"
    printf 'demo payload\n' >"$GSA_FAKE_SYNC_PAYLOAD"
    digest=$(sha256sum "$GSA_FAKE_SYNC_PAYLOAD")
    provider_srcinfo "$GSA_FAKE_SYNC_SRCINFO" demo 2.0.0 "${digest%% *}"

    recipe="$ws/packages/stable/demo"
    cp "$recipe/PKGBUILD" "$fixture/s2a/PKGBUILD.pre"
    run_sy "$ws" "$fixture/s2a/out" "$fixture/s2a/err" "$fixture/s2a/state"

    [ "$SY_RC" = 5 ] \
        || fail "a query-outage deferral exits 5 (§G.1), got $SY_RC:" "$fixture/s2a/err"
    grep -F 'demo: deferred (upstream-unverified)' "$fixture/s2a/err" >/dev/null \
        || fail "the deferral note does not name upstream-unverified:" "$fixture/s2a/err"
    grep -F 'nothing was built' "$fixture/s2a/err" >/dev/null \
        || fail "the deferral note must state nothing was built:" "$fixture/s2a/err"
    grep -F 'Version and checksum sync: nothing to do' "$fixture/s2a/out" >/dev/null \
        || fail "the disposition block is missing on a deferral:" "$fixture/s2a/out"
    cmp -s "$fixture/s2a/PKGBUILD.pre" "$recipe/PKGBUILD" \
        || fail "a query outage mutated the recipe:" "$recipe/PKGBUILD"

    # 2b — the query works and the REWRITE lands, but the checksum metadata
    # fetch dies at anchoring time: the recipe is RESTORED byte-identically
    # (the interesting restore — dirty had already gone true).
    ws="$fixture/s2b/ws"
    make_workspace "$ws" 1 1 low
    stable_recipe "$ws" demo
    write_stub_pacman "$ws"
    write_stub_curl "$ws"
    write_stub_updpkgsums "$ws"
    write_stub_makepkg "$ws"
    export PATH="$ws/bin:$PATH"
    export GSA_FAKE_SYNC_PACMAN_LOG="$fixture/s2b/pacman.log"
    export GSA_FAKE_SYNC_SI_LOG="$fixture/s2b/si.log"
    export GSA_FAKE_SYNC_SI_MODE=found
    export GSA_FAKE_SYNC_SI_VERSION=2.0.0-2
    export GSA_FAKE_SYNC_CURL_MODE=outage
    export GSA_FAKE_SYNC_MAKEPKG_LOG="$fixture/s2b/makepkg.log"
    export GSA_FAKE_SYNC_PAYLOAD="$fixture/s2b/payload"
    export GSA_FAKE_SYNC_STAGED_NAME=demo-2.0.0.tar.gz
    export GSA_FAKE_SYNC_SRCINFO="$fixture/s2b/provider.SRCINFO"
    printf 'demo payload\n' >"$GSA_FAKE_SYNC_PAYLOAD"
    digest=$(sha256sum "$GSA_FAKE_SYNC_PAYLOAD")
    provider_srcinfo "$GSA_FAKE_SYNC_SRCINFO" demo 2.0.0 "${digest%% *}"

    recipe="$ws/packages/stable/demo"
    cp "$recipe/PKGBUILD" "$fixture/s2b/PKGBUILD.pre"
    run_sy "$ws" "$fixture/s2b/out" "$fixture/s2b/err" "$fixture/s2b/state"

    [ "$SY_RC" = 5 ] \
        || fail "an anchoring-time outage defers (rc 5), got $SY_RC:" "$fixture/s2b/err"
    grep -F 'demo: deferred (anchoring-refused)' "$fixture/s2b/err" >/dev/null \
        || fail "the deferral note does not name anchoring-refused:" "$fixture/s2b/err"
    grep -F 'provider checksum metadata is unavailable' "$fixture/s2b/err" >/dev/null \
        || fail "the anchoring refusal does not name the outage:" "$fixture/s2b/err"
    cmp -s "$fixture/s2b/PKGBUILD.pre" "$recipe/PKGBUILD" \
        || fail "the failed anchor did not restore the recipe byte-identically:" "$recipe/PKGBUILD"
    grep -Fx 'pkgver=1.0.0' "$recipe/PKGBUILD" >/dev/null \
        || fail "the restore left the rewritten pkgver behind:" "$recipe/PKGBUILD"
)

# ─── 3. published checksum mismatch: integrity stop, restored, rc 3 ────────
(
    set -euo pipefail
    ws="$fixture/s3/ws"
    make_workspace "$ws" 1 1 low
    stable_recipe "$ws" demo
    write_stub_pacman "$ws"
    write_stub_curl "$ws"
    write_stub_updpkgsums "$ws"
    write_stub_makepkg "$ws"
    export PATH="$ws/bin:$PATH"
    export GSA_FAKE_SYNC_PACMAN_LOG="$fixture/s3/pacman.log"
    export GSA_FAKE_SYNC_SI_LOG="$fixture/s3/si.log"
    export GSA_FAKE_SYNC_SI_MODE=found
    export GSA_FAKE_SYNC_SI_VERSION=2.0.0-2
    export GSA_FAKE_SYNC_CURL_MODE=ok
    export GSA_FAKE_SYNC_MAKEPKG_LOG="$fixture/s3/makepkg.log"
    export GSA_FAKE_SYNC_PAYLOAD="$fixture/s3/payload"
    export GSA_FAKE_SYNC_STAGED_NAME=demo-2.0.0.tar.gz
    export GSA_FAKE_SYNC_SRCINFO="$fixture/s3/provider.SRCINFO"
    printf 'demo payload whose bytes the provider did NOT publish\n' >"$GSA_FAKE_SYNC_PAYLOAD"
    # the published digest is 64 zeroes: a DIFFERENT source, not a stale sum
    provider_srcinfo "$GSA_FAKE_SYNC_SRCINFO" demo 2.0.0 \
        0000000000000000000000000000000000000000000000000000000000000000

    recipe="$ws/packages/stable/demo"
    cp "$recipe/PKGBUILD" "$fixture/s3/PKGBUILD.pre"
    run_sy "$ws" "$fixture/s3/out" "$fixture/s3/err" "$fixture/s3/state"

    [ "$SY_RC" = 3 ] \
        || fail "an integrity stop exits 3 (§G.1), got $SY_RC:" "$fixture/s3/err"
    grep -F 'refusing to rewrite — integrity-stop' "$fixture/s3/err" >/dev/null \
        || fail "the refusal does not name the integrity stop:" "$fixture/s3/err"
    grep -F 'the recipe was restored byte-for-byte' "$fixture/s3/err" >/dev/null \
        || fail "the refusal must state the restore:" "$fixture/s3/err"
    grep -F 'refusing to build — a source does not match' "$fixture/s3/err" >/dev/null \
        || fail "the anchored mismatch is not reported:" "$fixture/s3/err"
    grep -F 'published value is 0000000000000000000000000000000000000000000000000000000000000000' \
        "$fixture/s3/err" >/dev/null \
        || fail "the mismatch report does not carry the published value:" "$fixture/s3/err"
    cmp -s "$fixture/s3/PKGBUILD.pre" "$recipe/PKGBUILD" \
        || fail "the integrity stop did not restore the recipe byte-identically:" "$recipe/PKGBUILD"
    [ ! -s "$GSA_FAKE_SYNC_MAKEPKG_LOG" ] \
        || fail "the integrity stop built something:" "$GSA_FAKE_SYNC_MAKEPKG_LOG"
)

# ─── 4. -Su: sync → stale set → build+install; noop; dry-run ───────────────
(
    set -euo pipefail
    ws="$fixture/s4/ws"
    make_workspace "$ws" 1 1 low
    stable_recipe "$ws" demo
    write_stub_pacman "$ws"
    write_stub_curl "$ws"
    write_stub_updpkgsums "$ws"
    write_stub_makepkg "$ws"
    stub_sudo "$ws"
    db="$fixture/s4/db"
    mkdir -p "$db"
    write_stub_pacman_conf "$ws" "$db"
    export PATH="$ws/bin:$PATH"
    export GSA_FAKE_SYNC_PACMAN_LOG="$fixture/s4/pacman.log"
    export GSA_FAKE_SYNC_SI_LOG="$fixture/s4/si.log"
    export GSA_FAKE_SYNC_SI_MODE=found
    export GSA_FAKE_SYNC_SI_VERSION=2.0.0-2
    export GSA_FAKE_SYNC_CURL_MODE=ok
    export GSA_FAKE_SYNC_MAKEPKG_LOG="$fixture/s4/makepkg.log"
    export GSA_FAKE_SYNC_PAYLOAD="$fixture/s4/payload"
    export GSA_FAKE_SYNC_STAGED_NAME=demo-2.0.0.tar.gz
    export GSA_FAKE_SYNC_SRCINFO="$fixture/s4/provider.SRCINFO"
    printf 'demo payload for 2.0.0\n' >"$GSA_FAKE_SYNC_PAYLOAD"
    digest=$(sha256sum "$GSA_FAKE_SYNC_PAYLOAD")
    provider_srcinfo "$GSA_FAKE_SYNC_SRCINFO" demo 2.0.0 "${digest%% *}"

    recipe="$ws/packages/stable/demo"
    state="$fixture/s4/state"
    # the built instance the stale set is measured against: 1.0.0-1 while the
    # provider will move the recipe to 2.0.0-2
    : >"$recipe/demo-1.0.0-1-any.pkg.tar.zst"

    # ── run 1: -Sy moves the version, the stale set is exactly that recipe,
    #    and the run builds + installs it (rule 11's pipeline) ─────────────
    run_engine "$ws" -Su --state-dir "$state" --config "$ws/pacman.conf" --no-prefetch
    {
        echo "$FIXTURE_OUTPUT"
    } >"$fixture/s4/run1.txt"
    [ "$FIXTURE_RC" = 0 ] \
        || fail "-Su with a stale recipe rc=$FIXTURE_RC, want 0:" "$fixture/s4/run1.txt"
    grep -F 'demo: 1.0.0-1 → 2.0.0-2 (synced with Arch repo)' "$fixture/s4/run1.txt" >/dev/null \
        || fail "-Su did not run the -Sy disposition:" "$fixture/s4/run1.txt"
    rr2_body <<<"$FIXTURE_OUTPUT" >/dev/null \
        || fail "-Su emitted no complete run record:" "$fixture/s4/run1.txt"
    [ "$(rr2_scalar order <<<"$FIXTURE_OUTPUT")" = "demo" ] \
        || fail "the stale set must be exactly [demo], order=$(rr2_scalar order <<<"$FIXTURE_OUTPUT"):" "$fixture/s4/run1.txt"
    [ "$(rr2_plan demo plan <<<"$FIXTURE_OUTPUT")" = "build-install" ] \
        || fail "the stale recipe's plan row is not build-install:" "$fixture/s4/run1.txt"
    [ "$(rr2_outcome demo status <<<"$FIXTURE_OUTPUT")" = "succeeded" ] \
        || fail "the stale recipe did not build:" "$fixture/s4/run1.txt"
    [ "$(rr2_outcome demo rc <<<"$FIXTURE_OUTPUT")" = "0" ] \
        || fail "the built row's rc is not 0:" "$fixture/s4/run1.txt"
    [ "$(rr2_outcome demo reason <<<"$FIXTURE_OUTPUT")" = "ok" ] \
        || fail "the built row's reason is not ok:" "$fixture/s4/run1.txt"
    grep -F 'makepkg ' "$GSA_FAKE_SYNC_MAKEPKG_LOG" >/dev/null \
        || fail "-Su never invoked makepkg:" "$GSA_FAKE_SYNC_MAKEPKG_LOG"
    grep -F 'pacman -U' "$GSA_FAKE_SYNC_PACMAN_LOG" >/dev/null \
        || fail "-Su never transacted the install:" "$GSA_FAKE_SYNC_PACMAN_LOG"
    [ -f "$recipe/demo-2.0.0-2-any.pkg.tar.zst" ] \
        || fail "the stub build produced no archive at the new version"

    # ── run 2: re-run with nothing stale — §E.3's noop empty-list, rc 0 ───
    run_engine "$ws" -Su --state-dir "$state" --config "$ws/pacman.conf" --no-prefetch
    {
        echo "$FIXTURE_OUTPUT"
    } >"$fixture/s4/run2.txt"
    [ "$FIXTURE_RC" = 0 ] || fail "-Su with nothing stale rc=$FIXTURE_RC, want 0:" "$fixture/s4/run2.txt"
    grep -F 'Version and checksum sync: nothing to do' "$fixture/s4/run2.txt" >/dev/null \
        || fail "the re-run's sync phase is not a no-op:" "$fixture/s4/run2.txt"
    # budget-less record: lanes: - cannot pass rr2_'s strict scalar grammar
    # (gsa-install-v2's precedent) — assert the raw rows instead.
    block=$(record_block "$fixture/s4/run2.txt")
    printf '%s\n' "$block" | grep -Fx -- '- noop empty-list' >/dev/null \
        || fail "the empty stale set must plan '- noop empty-list':" "$fixture/s4/run2.txt"
    printf '%s\n' "$block" | grep -Fx -- '- succeeded 0 - empty-list' >/dev/null \
        || fail "the empty stale set must settle '- succeeded 0 - empty-list':" "$fixture/s4/run2.txt"
    printf '%s\n' "$block" | grep -Fx -- 'rc: 0' >/dev/null \
        || fail "the noop record's rc scalar is not 0:" "$fixture/s4/run2.txt"

    # ── run 3: -Su --dry-run — the plan record only, nothing mutated. A live
    #    -Sy first stages a STALE recipe state (3.0.0 tracked vs 2.0.0-2
    #    built); the dry run then faces a provider version (4.0.0) that WOULD
    #    rewrite again and must neither query nor rewrite nor build. ───────
    export GSA_FAKE_SYNC_SI_VERSION=3.0.0-1
    export GSA_FAKE_SYNC_STAGED_NAME=demo-3.0.0.tar.gz
    digest3=$(sha256sum "$GSA_FAKE_SYNC_PAYLOAD")
    provider_srcinfo "$GSA_FAKE_SYNC_SRCINFO" demo 3.0.0 "${digest3%% *}"
    run_sy "$ws" "$fixture/s4/sy3.out" "$fixture/s4/sy3.err" "$state"
    [ "$SY_RC" = 0 ] || fail "staging -Sy rc=$SY_RC, want 0:" "$fixture/s4/sy3.err"
    grep -Fx 'pkgver=3.0.0' "$recipe/PKGBUILD" >/dev/null \
        || fail "the staging -Sy did not rewrite pkgver to 3.0.0:" "$recipe/PKGBUILD"
    cp "$recipe/PKGBUILD" "$fixture/s4/PKGBUILD.pre-dry"
    si_before=$(wc -l <"$GSA_FAKE_SYNC_SI_LOG")
    mk_before=$(wc -l <"$GSA_FAKE_SYNC_MAKEPKG_LOG")

    export GSA_FAKE_SYNC_SI_VERSION=4.0.0-1
    run_engine "$ws" -Su --dry-run --state-dir "$state" --config "$ws/pacman.conf" --no-prefetch
    {
        echo "$FIXTURE_OUTPUT"
    } >"$fixture/s4/run3.txt"
    [ "$FIXTURE_RC" = 0 ] || fail "-Su --dry-run rc=$FIXTURE_RC, want 0:" "$fixture/s4/run3.txt"
    block=$(record_block "$fixture/s4/run3.txt")
    printf '%s\n' "$block" | grep -Fx -- 'demo build-install ok' >/dev/null \
        || fail "the dry-run plan record must plan the stale recipe:" "$fixture/s4/run3.txt"
    printf '%s\n' "$block" | grep -Fx -- 'demo never-started - - dry-run' >/dev/null \
        || fail "the dry-run outcome row must be never-started/dry-run:" "$fixture/s4/run3.txt"
    printf '%s\n' "$block" | grep -Fx -- 'dry-run: yes' >/dev/null \
        || fail "the dry-run record must carry the dry-run: yes scalar:" "$fixture/s4/run3.txt"
    cmp -s "$fixture/s4/PKGBUILD.pre-dry" "$recipe/PKGBUILD" \
        || fail "-Su --dry-run rewrote the recipe:" "$recipe/PKGBUILD"
    [ "$(wc -l <"$GSA_FAKE_SYNC_SI_LOG")" = "$si_before" ] \
        || fail "-Su --dry-run queried the provider (it must run no sync)"
    [ "$(wc -l <"$GSA_FAKE_SYNC_MAKEPKG_LOG")" = "$mk_before" ] \
        || fail "-Su --dry-run invoked makepkg:" "$GSA_FAKE_SYNC_MAKEPKG_LOG"
)

# ─── 5. skip claims (--skip / --skip-built) and the --no-sync no-query proof ─
(
    set -euo pipefail
    ws="$fixture/s5/ws"
    make_workspace "$ws" 1 1 low
    add_package "$ws" skipdemo "$gsa_meta_any" git
    stable_recipe "$ws" qdemo # the -Sy-eligible recipe for the --no-sync proof
    write_stub_pacman "$ws"
    write_stub_curl "$ws"
    write_stub_updpkgsums "$ws"
    write_stub_makepkg "$ws"
    export PATH="$ws/bin:$PATH"
    export GSA_FAKE_SYNC_PACMAN_LOG="$fixture/s5/pacman.log"
    export GSA_FAKE_SYNC_SI_LOG="$fixture/s5/si.log"
    export GSA_FAKE_SYNC_SI_MODE=unknown
    export GSA_FAKE_SYNC_CURL_MODE=ok
    export GSA_FAKE_SYNC_MAKEPKG_LOG="$fixture/s5/makepkg.log"
    export GSA_FAKE_SYNC_PAYLOAD="$fixture/s5/payload"
    export GSA_FAKE_SYNC_STAGED_NAME=qdemo-1.0.0.tar.gz
    export GSA_FAKE_SYNC_SRCINFO="$fixture/s5/provider.SRCINFO"
    printf 'qdemo payload\n' >"$GSA_FAKE_SYNC_PAYLOAD"
    digest=$(sha256sum "$GSA_FAKE_SYNC_PAYLOAD")
    provider_srcinfo "$GSA_FAKE_SYNC_SRCINFO" qdemo 1.0.0 "${digest%% *}"
    state="$fixture/s5/state"
    # Pre-create the stub logs fixture-side (W5): the engine runs the pacman
    # stubs as root, so a root-created log would block the plain `: >` reset
    # before the --no-sync proof below with Permission denied.
    : >"$GSA_FAKE_SYNC_SI_LOG"
    : >"$GSA_FAKE_SYNC_PACMAN_LOG"
    : >"$GSA_FAKE_SYNC_MAKEPKG_LOG"

    # run A: a REAL build — it stages the claim's evidence (the archive) and
    # the toolchain marker the drift gate reads on the claim runs
    run_engine "$ws" -B --state-dir "$state" --no-prefetch skipdemo
    {
        echo "$FIXTURE_OUTPUT"
    } >"$fixture/s5/runA.txt"
    [ "$FIXTURE_RC" = 0 ] || fail "the staging build rc=$FIXTURE_RC, want 0:" "$fixture/s5/runA.txt"
    [ -f "$ws/packages/skipdemo/skipdemo-1.0.0-1-any.pkg.tar.zst" ] \
        || fail "the staging build produced no archive"
    mk_built=$(wc -l <"$GSA_FAKE_SYNC_MAKEPKG_LOG")

    # run B: --skip claims the fresh set — no lane, no makepkg
    run_engine "$ws" -B --skip --state-dir "$state" --no-prefetch skipdemo
    {
        echo "$FIXTURE_OUTPUT"
    } >"$fixture/s5/runB.txt"
    [ "$FIXTURE_RC" = 0 ] || fail "--skip claim rc=$FIXTURE_RC, want 0:" "$fixture/s5/runB.txt"
    rr2_body <<<"$FIXTURE_OUTPUT" >/dev/null \
        || fail "--skip emitted no complete run record:" "$fixture/s5/runB.txt"
    [ "$(rr2_plan skipdemo plan <<<"$FIXTURE_OUTPUT")" = "skip" ] \
        || fail "a --skip claim must plan 'skip':" "$fixture/s5/runB.txt"
    [ "$(rr2_plan skipdemo reason <<<"$FIXTURE_OUTPUT")" = "ok" ] \
        || fail "a fresh --skip claim's reason must be ok (§H.3):" "$fixture/s5/runB.txt"
    [ "$(rr2_outcome skipdemo status <<<"$FIXTURE_OUTPUT")" = "succeeded" ] \
        || fail "a claim settles as succeeded:" "$fixture/s5/runB.txt"
    [ "$(rr2_outcome skipdemo rc <<<"$FIXTURE_OUTPUT")" = "-" ] \
        || fail "a claim row has no lane rc:" "$fixture/s5/runB.txt"
    [ "$(rr2_outcome skipdemo reason <<<"$FIXTURE_OUTPUT")" = "ok" ] \
        || fail "a claim row keeps its claim reason, never a bare build reason:" "$fixture/s5/runB.txt"
    [ "$(wc -l <"$GSA_FAKE_SYNC_MAKEPKG_LOG")" = "$mk_built" ] \
        || fail "--skip dispatched makepkg although it claimed the set:" "$GSA_FAKE_SYNC_MAKEPKG_LOG"

    # run C: --skip-built — the freshness-blind claim, its own reason key
    run_engine "$ws" -B --skip-built --state-dir "$state" --no-prefetch skipdemo
    {
        echo "$FIXTURE_OUTPUT"
    } >"$fixture/s5/runC.txt"
    [ "$FIXTURE_RC" = 0 ] || fail "--skip-built claim rc=$FIXTURE_RC, want 0:" "$fixture/s5/runC.txt"
    rr2_body <<<"$FIXTURE_OUTPUT" >/dev/null \
        || fail "--skip-built emitted no complete run record:" "$fixture/s5/runC.txt"
    [ "$(rr2_plan skipdemo plan <<<"$FIXTURE_OUTPUT")" = "skip" ] \
        || fail "a --skip-built claim must plan 'skip':" "$fixture/s5/runC.txt"
    [ "$(rr2_plan skipdemo reason <<<"$FIXTURE_OUTPUT")" = "skip-built" ] \
        || fail "a --skip-built claim's reason must be skip-built (§H.3):" "$fixture/s5/runC.txt"
    [ "$(rr2_outcome skipdemo reason <<<"$FIXTURE_OUTPUT")" = "skip-built" ] \
        || fail "a --skip-built row keeps its own claim reason:" "$fixture/s5/runC.txt"
    [ "$(wc -l <"$GSA_FAKE_SYNC_MAKEPKG_LOG")" = "$mk_built" ] \
        || fail "--skip-built dispatched makepkg although it claimed the set:" "$GSA_FAKE_SYNC_MAKEPKG_LOG"

    # run D: --no-sync on the -Sy-eligible recipe — NO provider query at all
    : >"$GSA_FAKE_SYNC_SI_LOG"
    run_engine "$ws" -B --no-sync --state-dir "$state" --no-prefetch qdemo
    {
        echo "$FIXTURE_OUTPUT"
    } >"$fixture/s5/runD.txt"
    [ "$FIXTURE_RC" = 0 ] || fail "--no-sync build rc=$FIXTURE_RC, want 0:" "$fixture/s5/runD.txt"
    [ ! -s "$GSA_FAKE_SYNC_SI_LOG" ] \
        || fail "--no-sync still queried the provider:" "$GSA_FAKE_SYNC_SI_LOG"
    [ "$(rr2_outcome qdemo status <<<"$FIXTURE_OUTPUT")" = "succeeded" ] \
        || fail "--no-sync must still build the committed version:" "$fixture/s5/runD.txt"
    grep -F 'makepkg ' "$GSA_FAKE_SYNC_MAKEPKG_LOG" >/dev/null \
        || fail "the --no-sync run built nothing (the proof would be vacuous)"

    # control: the SAME run without --no-sync queries — an empty query log
    # above is only meaningful because this run fills it
    run_engine "$ws" -B --state-dir "$state" --no-prefetch qdemo
    [ "$FIXTURE_RC" = 0 ] || fail "the control build rc=$FIXTURE_RC, want 0"
    [ -s "$GSA_FAKE_SYNC_SI_LOG" ] \
        || fail "the provider-query log is dead — the --no-sync proof proves nothing"
)

# ─── 6. toolchain preflight: broken rustc refuses, --allow-broken-rustc goes ─
(
    set -euo pipefail
    ws="$fixture/s6/ws"
    make_workspace "$ws" 1 1 low
    add_package "$ws" rustdemo "$gsa_meta_any" git
    write_stub_pacman "$ws"
    write_stub_makepkg "$ws"
    write_stub_rustc "$ws"
    export PATH="$ws/bin:$PATH"
    export GSA_FAKE_SYNC_PACMAN_LOG="$fixture/s6/pacman.log"
    export GSA_FAKE_SYNC_SI_LOG="$fixture/s6/si.log"
    export GSA_FAKE_SYNC_SI_MODE=unknown
    export GSA_FAKE_SYNC_RUSTGIT=installed # the probe's engagement gate
    export GSA_FAKE_SYNC_MAKEPKG_LOG="$fixture/s6/makepkg.log"
    state="$fixture/s6/state"

    run_engine "$ws" -B --state-dir "$state" --no-prefetch rustdemo
    {
        echo "$FIXTURE_OUTPUT"
    } >"$fixture/s6/refused.txt"
    [ "$FIXTURE_RC" = 3 ] \
        || fail "a broken rustc must refuse the run (rc 3), got $FIXTURE_RC:" "$fixture/s6/refused.txt"
    rr2_body <<<"$FIXTURE_OUTPUT" >/dev/null \
        || fail "the preflight refusal emitted no complete run record:" "$fixture/s6/refused.txt"
    [ "$(rr2_scalar rc <<<"$FIXTURE_OUTPUT")" = "3" ] \
        || fail "the refusal record's rc scalar is not 3:" "$fixture/s6/refused.txt"
    while read -r pkg status rc dur reason; do
        [ "$status" = "never-started" ] \
            || fail "preflight refusal: $pkg is $status, want never-started:" "$fixture/s6/refused.txt"
        [ "$rc" = "-" ] && [ "$dur" = "-" ] \
            || fail "preflight refusal: $pkg row must carry - - for rc/dur:" "$fixture/s6/refused.txt"
        [ "$reason" = "preflight-refused" ] \
            || fail "preflight refusal: $pkg reason is $reason, want preflight-refused:" "$fixture/s6/refused.txt"
    done < <(rr2_outcome_rows <<<"$FIXTURE_OUTPUT")
    [ "$(rr2_plan rustdemo plan <<<"$FIXTURE_OUTPUT")" = "build" ] \
        || fail "the refused run keeps its planned action:" "$fixture/s6/refused.txt"
    grep -F 'rustc is BROKEN' "$fixture/s6/refused.txt" >/dev/null \
        || fail "the refusal does not name the broken toolchain:" "$fixture/s6/refused.txt"
    grep -F 'Bypass anyway: --allow-broken-rustc' "$fixture/s6/refused.txt" >/dev/null \
        || fail "the refusal must name the escape hatch:" "$fixture/s6/refused.txt"
    [ ! -s "$GSA_FAKE_SYNC_MAKEPKG_LOG" ] \
        || fail "the refused run dispatched a build:" "$GSA_FAKE_SYNC_MAKEPKG_LOG"

    # the escape hatch: the probe is skipped entirely and the run proceeds
    run_engine "$ws" -B --allow-broken-rustc --state-dir "$state" --no-prefetch rustdemo
    {
        echo "$FIXTURE_OUTPUT"
    } >"$fixture/s6/bypass.txt"
    [ "$FIXTURE_RC" = 0 ] \
        || fail "--allow-broken-rustc must proceed to build, rc=$FIXTURE_RC:" "$fixture/s6/bypass.txt"
    rr2_body <<<"$FIXTURE_OUTPUT" >/dev/null \
        || fail "the bypass run emitted no complete run record:" "$fixture/s6/bypass.txt"
    [ "$(rr2_outcome rustdemo status <<<"$FIXTURE_OUTPUT")" = "succeeded" ] \
        || fail "the bypass run did not build rustdemo:" "$fixture/s6/bypass.txt"
    [ "$(rr2_outcome rustdemo rc <<<"$FIXTURE_OUTPUT")" = "0" ] \
        || fail "the bypass build row's rc is not 0:" "$fixture/s6/bypass.txt"
    grep -F 'makepkg ' "$GSA_FAKE_SYNC_MAKEPKG_LOG" >/dev/null \
        || fail "the bypass run never invoked makepkg:" "$GSA_FAKE_SYNC_MAKEPKG_LOG"
)

printf 'gsa sync v2 fixture: PASS\n'
