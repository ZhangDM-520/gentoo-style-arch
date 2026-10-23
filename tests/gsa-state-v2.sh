#!/usr/bin/env bash
set -euo pipefail

# tests/gsa-state-v2.sh — the side-car state database of the NATIVE engine
# (`gsa`, docs/gsa-contract.md §J/§H.1/§B.3/§D.1/§G). Everything here is
# synthetic: $TMPDIR workspaces, stub `makepkg`/`sudo`/`pacman` executables,
# and a `--state-dir` override per section — the real `/var/lib/gsa` is
# never read or written (asserted in section f and again at fixture end).
# Expectations are DERIVED (rule 25(j) / contract §L.3): the expected `-Qb`
# wire rows are computed from the index records AND the archive bytes
# (`sha256sum`/`stat`), retention counts come from the index records the
# runs produced, and the run-history blocks are diffed against the very
# blocks the runs emitted (§H.1: persistence is storage of the same
# structure, not a fourth derivation).
#
# Pinned here (six ( subshell ) sections, one per scenario; run one alone
# with GSA_STATE_V2_ONLY=a…f):
#   a. index registration after a stub build (§J.4): one row per built
#      instance bound to the archive's sha256+size, `-Qb` renders the §J.4
#      wire row, `-Qp` agrees with the row and the bytes.
#   b. retention (owner decision 2): a hub (`core` or ≥2 consumers — derived
#      from this fixture's own topology edges, never a name) keeps 2 built
#      instances after three builds, a leaf keeps 1 after two; the pruned
#      instances are tombstoned and their archive files deleted, loudly.
#   c. the in-flight guard (§J.4/§K.1): with a leaf's lane stalled and its
#      index over budget, another package's registration DEFERS the sweep
#      (note names the leaf, its rows and archive survive the mid-run read);
#      once the lane settles the next sweep converges to the budget.
#   d. query surfaces (§B.3): `-Qb [ref…]` filters rows by resolved ref and
#      prints rows derived from the records; `-Qp <archive…>` reports
#      hash/size agreement (`agrees`), a tampered archive (`mismatch`,
#      hash/size disagree), an unrecorded one (`unindexed`), and rc 2 usage
#      refusals naming the argument.
#   e. `--local-db-check` (§D.1/§G): rc 0 on a clean side-car; a corrupted
#      row is CAUGHT BY NAME (rc 1); an orphan archive is named; the
#      `runs` verb renders the stored `format: 2` records — byte-identical
#      to what the runs emitted — for completed AND interrupted (rc 130)
#      runs (§H.1).
#   f. state-dir override (§J.3): `--state-dir` and `GSA_STATE_DIR` keep
#      every byte inside $TMPDIR, and the real /var/lib/gsa is untouched.
#
# Red-first (contract §L.4): retention and the hash binding are mutation-
# probed during development — breaking `Retention::keep_for` or the
# `hash_archive` divergence check makes sections b/a fail naming the
# subject; the probe restores the source byte-identical and `touch`es it.
#
# House conventions: `( subshell )` sections (each an isolated scenario with
# its own workspace and state root), inline oracle stubs (§D.2), `fail()`
# prefixes, and tests/lib/rr-v2.bash's `format: 2` parser + run_engine with
# GSA_TEST_ENGINE=gsa.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"

fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-state-v2.XXXXXX")
# root-safe cleanup: engine state under $fixture is root-owned (W5 §B.10)
trap '/usr/bin/sudo -n rm -rf -- "$fixture" 2>/dev/null || rm -rf -- "$fixture" 2>/dev/null || true' EXIT

fail() {
    printf '%s\n' "$1" >&2
    if [ -n "${2:-}" ] && [ -f "$2" ]; then
        sed 's/^/    /' "$2" >&2
    fi
    exit 1
}

# Section filter: GSA_STATE_V2_ONLY=<a..f> runs exactly one section.
want() { [ -z "${GSA_STATE_V2_ONLY:-}" ] || [ "${GSA_STATE_V2_ONLY}" = "$1" ]; }

# ─── Stub-knob vocabulary (§D.2: declared here in the change that adds them) ─
rr2_stub_knob GSA_FAKE_COUNT_DIR "gsa-state-v2 makepkg stub: per-package build counter (drives distinct versions per instance)"
rr2_stub_knob GSA_FAKE_STALL_PACKAGE "gsa-state-v2 makepkg stub: package id whose build blocks on the release file (in-flight guard)"
rr2_stub_knob GSA_FAKE_RELEASE_FILE "gsa-state-v2 makepkg stub: file whose existence releases the stalled build"

# The real /var/lib/gsa must never move under this fixture (§J.3's rule that
# fixtures live behind an override): snapshot its listing now and compare at
# the end of the fixture and inside section f.
varlib_before=$( (find /var/lib/gsa -printf '%p %s %T@\n' 2>/dev/null || true) | sort | md5sum)

# ─── The engine under test: the INSTALLED binary (contract §L.10 — smoke
# test what the user runs — never a nested target/ build). GSA_TEST_GSA_BIN
# is the explicit pre-install override (rr-v2.bash run_engine convention). ──────
if [ -z "${GSA_TEST_GSA_BIN:-}" ]; then
    GSA_TEST_GSA_BIN=$(command -v gsa) || {
        printf 'contract §L.10: no installed gsa on PATH — install gsa-pm, or set GSA_TEST_GSA_BIN explicitly\n' >&2
        exit 1
    }
fi
[ -x "$GSA_TEST_GSA_BIN" ] || fail "the engine under test is not executable: $GSA_TEST_GSA_BIN"
export GSA_TEST_ENGINE=gsa
export GSA_TEST_GSA_BIN

# ─── Oracle stubs and derivation helpers (inline: §D.2 keeps oracles in the
# fixture that gives them meaning) ──────────────────────────────────────────

# stage_pkginfo STAGE PKGBASE PKGNAME PKGVER — the staged `.PKGINFO` of one
# hand-built archive (the metadata truth rule 9 makes authoritative).
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

# make_archive OUT STAGE — one real `.pkg.tar.zst` from a prepared stage dir.
# The stage is consumed.
make_archive() {
    local out=$1 stage=$2
    mkdir -p "$(dirname "$out")"
    tar --zstd -cf "$out" -C "$stage" .PKGINFO
    rm -rf -- "$stage"
}

# write_stub_makepkg DIR — the scenario makepkg: one real `.pkg.tar.zst` per
# build with a counter-derived version (so every registration is a fresh
# instance), plus the in-flight stall (GSA_FAKE_STALL_PACKAGE blocks until
# GSA_FAKE_RELEASE_FILE exists).
write_stub_makepkg() {
    cat >"$1/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -eu
case " $* " in
*" --verifysource "*) exit 0 ;; # fetch children are advisory here
esac
id=$(basename "$PWD")
n=$(cat "${GSA_FAKE_COUNT_DIR:?}/$id" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s\n' "$n" >"${GSA_FAKE_COUNT_DIR:?}/$id"
if [ "$id" = "${GSA_FAKE_STALL_PACKAGE:-}" ]; then
    while [ ! -e "${GSA_FAKE_RELEASE_FILE:?}" ]; do
        sleep 0.05
    done
fi
stage="$PWD/.stage-$id-$n"
mkdir -p "$stage"
{
    printf 'pkgbase = %s\n' "$id"
    printf 'pkgname = %s\n' "$id"
    printf 'pkgver = 1.0.%s-1\n' "$n"
    printf 'arch = any\n'
} >"$stage/.PKGINFO"
tar --zstd -cf "$PWD/$id-1.0.$n-1-any.pkg.tar.zst" -C "$stage" .PKGINFO
rm -rf "$stage"
exit 0
EOF
    chmod +x "$1/bin/makepkg"
}

# state_ws DIR — one workspace with the stubs on PATH (the sudo/pacman
# passthroughs keep any accidental escalation away from the host).
state_ws() {
    local ws=$1
    write_stub_makepkg "$ws"
    stub_sudo "$ws"
    stub_pacman "$ws"
    export PATH="$ws/bin:$PATH"
    export GSA_FAKE_COUNT_DIR="$ws/counts"
    mkdir -p "$GSA_FAKE_COUNT_DIR"
    : >"$ws/bin/.pacman.log"
    export GSA_FAKE_PACMAN_LOG="$ws/bin/.pacman.log"
}

# json_field LINE FIELD — one string field of an index record (the records
# are single-line JSON; expectations derive from them, rule 25(j)).
json_field() {
    printf '%s\n' "$1" | sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p" | head -n 1
}

# json_num LINE FIELD — one numeric field of an index record.
json_num() {
    printf '%s\n' "$1" | sed -n "s/.*\"$2\":\([0-9][0-9]*\).*/\1/p" | head -n 1
}

# index_rows STATE [RECIPE] — the live index rows (prune tombstones drop
# rows from the fold, so the fixture folds the same way: a row followed by
# its `op":"prune"` tombstone is dead).
index_rows() {
    local state=$1 recipe=${2:-}
    awk '
        /"op":"prune"/ {
            match($0, /"recipe_id":"[^"]*"/); r = substr($0, RSTART + 13, RLENGTH - 14)
            match($0, /"instance":[0-9]+/); i = substr($0, RSTART + 11, RLENGTH - 11)
            dead[r "|" i] = 1
            next
        }
        /"op":"row"/ {
            match($0, /"recipe_id":"[^"]*"/); r = substr($0, RSTART + 13, RLENGTH - 14)
            match($0, /"instance":[0-9]+/); i = substr($0, RSTART + 11, RLENGTH - 11)
            key = r "|" i
            if (key in seen) next
            seen[key] = 1
            live[key] = $0
            order[++count] = key
        }
        END {
            for (n = 1; n <= count; n++) {
                key = order[n]
                if (key in dead) continue
                if (want != "" && index(key, want "|") != 1) continue
                print live[key]
            }
        }
    ' "want=$recipe" "$state/index/binpkg.jsonl" 2>/dev/null || true
}

# wire_from_record LINE ARCHIVE — the §J.4 wire row EXPECTED for one index
# record: every field from the record — including `abi_token`, the one
# shared derivation (`gsa-abi`) registered at write time — with the hash and
# size re-derived from the archive's bytes (so `-Qb` must agree with both
# the record and the file).
wire_from_record() {
    local line=$1 archive=$2
    local pkgbase name version fname sha size built token
    pkgbase=$(json_field "$line" pkgbase)
    name=$(printf '%s\n' "$line" | sed -n 's/.*"pkgnames":\["\([^"]*\)"\].*/\1/p')
    version=$(json_field "$line" version)
    fname=$(basename "$(json_field "$line" archive)")
    sha=$(sha256sum "$archive" | awk '{print $1}')
    size=$(stat -c%s "$archive")
    built=$(json_num "$line" built_at)
    token=$(json_field "$line" abi_token)
    printf '%s|%s|%s|%s|%s|%s|%s|-|-|%s\n' \
        "$pkgbase" "$name" "$version" "$fname" "$sha" "$size" "$token" "$built"
}

# ─── a. index registration after a stub build (§J.4) ───────────────────────
if want a; then
    (
        set -euo pipefail
        ws="$fixture/a/ws"
        state="$fixture/a/state"
        make_workspace "$ws" 1 auto low
        state_ws "$ws"
        export GSA_STATE_DIR="$state"
        add_package "$ws" alpha "$gsa_meta_any" git

        run_engine "$ws" -B --no-prefetch --state-dir "$state" alpha
        [ "$FIXTURE_RC" = 0 ] || fail "a clean build is rc 0 (§G.1), got $FIXTURE_RC: $FIXTURE_OUTPUT"
        rr2_body <<<"$FIXTURE_OUTPUT" >/dev/null || fail "no complete run record: $FIXTURE_OUTPUT"

        # One row per built instance, hash-bound at write time (§J.4).
        rows=$(index_rows "$state" alpha)
        [ "$(printf '%s\n' "$rows" | grep -c '"op":"row"')" = 1 ] \
            || fail "one build registers exactly one instance, got rows:
$rows"
        archive="$ws/packages/alpha/alpha-1.0.1-1-any.pkg.tar.zst"
        [ -f "$archive" ] || fail "the stub build produced no archive: $archive"
        row_sha=$(json_field "$rows" sha256)
        row_size=$(json_num "$rows" size)
        want_sha=$(sha256sum "$archive" | awk '{print $1}')
        want_size=$(stat -c%s "$archive")
        [ "$row_sha" = "$want_sha" ] \
            || fail "the row's sha256 must bind the archive bytes (§J.4): row=$row_sha bytes=$want_sha"
        [ "$row_size" = "$want_size" ] \
            || fail "the row's size must bind the archive bytes (§J.4): row=$row_size bytes=$want_size"
        [ "$(json_field "$rows" version)" = "0:1.0.1-1" ] \
            || fail "the row's version is the .PKGINFO truth: $(json_field "$rows" version)"

        # `-Qb` prints the §J.4 wire row derived from the record + bytes.
        run_engine "$ws" -Qb --state-dir "$state"
        [ "$FIXTURE_RC" = 0 ] || fail "-Qb is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        expected=$(wire_from_record "$rows" "$archive")
        [ "$(printf '%s\n' "$FIXTURE_OUTPUT")" = "$expected" ] \
            || fail "-Qb must print the record-derived wire row (rule 25(j)):
want: $expected
got:  $FIXTURE_OUTPUT"

        # `-Qp` agrees: .PKGINFO + index row + bytes (§B.3).
        run_engine "$ws" -Qp --state-dir "$state" "$archive"
        [ "$FIXTURE_RC" = 0 ] || fail "-Qp is rc 0, got $FIXTURE_RC"
        vgrep "$FIXTURE_OUTPUT" -F "agrees pkginfo=ok" >/dev/null \
            || fail "-Qp must report agreement for a registered archive (§B.3): $FIXTURE_OUTPUT"
        vgrep "$FIXTURE_OUTPUT" -F "hash=agree size=agree" >/dev/null \
            || fail "-Qp must report hash/size agreement (§B.3): $FIXTURE_OUTPUT"
    )
fi

# ─── b. retention: hub keeps 2, leaf keeps 1 (owner decision 2) ────────────
if want b; then
    (
        set -euo pipefail
        ws="$fixture/b/ws"
        state="$fixture/b/state"
        make_workspace "$ws" 1 auto low
        state_ws "$ws"
        export GSA_STATE_DIR="$state"
        # The hub's hub-ness is topology-derived: two consumers name it in
        # their build-order edges (never a hardcoded name).
        add_package "$ws" hub "$gsa_meta_any" git
        add_package "$ws" fan-a "$gsa_meta_any" git
        add_package "$ws" fan-b "$gsa_meta_any" git
        set_topology_record "$ws" fan-a git hub
        set_topology_record "$ws" fan-b git hub
        add_package "$ws" leaf "$gsa_meta_any" git

        for n in 1 2 3; do
            run_engine "$ws" -B --no-prefetch --leaf --state-dir "$state" hub
            [ "$FIXTURE_RC" = 0 ] || fail "hub build $n is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        done
        hub_out=$FIXTURE_OUTPUT
        for n in 1 2; do
            run_engine "$ws" -B --no-prefetch --leaf --state-dir "$state" leaf
            [ "$FIXTURE_RC" = 0 ] || fail "leaf build $n is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        done
        leaf_out=$FIXTURE_OUTPUT

        hub_rows=$(index_rows "$state" hub)
        leaf_rows=$(index_rows "$state" leaf)
        hub_count=$(printf '%s\n' "$hub_rows" | grep -c '"op":"row"')
        leaf_count=$(printf '%s\n' "$leaf_rows" | grep -c '"op":"row"')
        [ "$hub_count" = 2 ] \
            || fail "a hub (≥2 consumers) keeps 2 built instances, got $hub_count:
$hub_rows"
        [ "$leaf_count" = 1 ] \
            || fail "a leaf keeps 1 built instance, got $leaf_count:
$leaf_rows"
        # The survivors are the NEWEST instances (derived from the records).
        hub_instances=$(printf '%s\n' "$hub_rows" | while IFS= read -r row; do json_num "$row" instance; done | sort -n | tr '\n' ' ')
        [ "$hub_instances" = "2 3 " ] \
            || fail "the hub keeps its two newest instances (2 3), got: $hub_instances"
        leaf_instances=$(printf '%s\n' "$leaf_rows" | while IFS= read -r row; do json_num "$row" instance; done | sort -n | tr '\n' ' ')
        [ "$leaf_instances" = "2 " ] \
            || fail "the leaf keeps its newest instance (2), got: $leaf_instances"

        # Pruned instances lose their archive files too, loudly (§J.4).
        hub_archives=$(find "$ws/packages/hub" -name 'hub-*.pkg.tar.zst' | wc -l)
        leaf_archives=$(find "$ws/packages/leaf" -name 'leaf-*.pkg.tar.zst' | wc -l)
        [ "$hub_archives" = 2 ] || fail "the pruned hub archive is deleted, $hub_archives left"
        [ "$leaf_archives" = 1 ] || fail "the pruned leaf archives are deleted, $leaf_archives left"
        printf '%s\n' "$hub_out" | grep -F "msg=binpkg_index:_retention_pruned_hub_instance_1" >/dev/null \
            || fail "the hub pruning is announced by name in its own run: $hub_out"
        printf '%s\n' "$leaf_out" | grep -F "msg=binpkg_index:_retention_pruned_leaf_instance" >/dev/null \
            || fail "the leaf pruning is announced by name in its own run: $leaf_out"
    )
fi

# ─── c. the in-flight guard: pruning defers for lanes still building ───────
if want c; then
    (
        set -euo pipefail
        ws="$fixture/c/ws"
        state="$fixture/c/state"
        make_workspace "$ws" 2 auto low
        state_ws "$ws"
        export GSA_STATE_DIR="$state"
        add_package "$ws" slow "$gsa_meta_any" git
        add_package "$ws" quick "$gsa_meta_any" git

        # Instance 1: a real build.
        run_engine "$ws" -B --no-prefetch --leaf --state-dir "$state" slow
        [ "$FIXTURE_RC" = 0 ] || fail "the seeding build is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"

        # Instance 2 (history the guard will protect): a staged archive plus
        # its index record — the same record shape the engine writes, with
        # the hash/size derived from the staged bytes.
        stage="$fixture/c/stage"
        stage_pkginfo "$stage" slow slow 1.0.9-1
        old="$ws/packages/slow/slow-1.0.9-1-any.pkg.tar.zst"
        make_archive "$old" "$stage"
        sha=$(sha256sum "$old" | awk '{print $1}')
        size=$(stat -c%s "$old")
        # the index is engine-owned state (W5 §B.10) — seed the row through
        # the host's REAL sudo, never the PATH stub
        printf '{"op":"row","recipe_id":"slow","pkgbase":"slow","pkgnames":["slow"],"version":"0:1.0.9-1","archive":"%s","sha256":"%s","size":%s,"built_at":1,"abi_token":"-","provides":[],"vcs_baseline":"-","instance":2}\n' \
            "$old" "$sha" "$size" | /usr/bin/sudo -n tee -a "$state/index/binpkg.jsonl" >/dev/null
        [ "$(index_rows "$state" slow | grep -c '"op":"row"')" = 2 ] \
            || fail "the staged history must read back as two slow instances"

        # The run: `slow`'s lane blocks on the release file, `quick` builds
        # and registers while `slow` is still in flight.
        release="$fixture/c/release"
        runlog="$fixture/c/run.log"
        export GSA_FAKE_STALL_PACKAGE=slow
        export GSA_FAKE_RELEASE_FILE="$release"
        (
            cd "$ws"
            # W5 §B.10: a direct engine invocation must model run_engine's
            # privileged form — /usr/bin/sudo -n env <forwarded fixture env>
            # (sudo's env_reset strips the stub PATH and every GSA_FAKE_*
            # knob; rr2_env_forward is the same whitelist run_engine uses)
            fwd=()
            rr2_env_forward fwd
            /usr/bin/sudo -n env "${fwd[@]}" "$GSA_TEST_GSA_BIN" -B --no-prefetch --state-dir "$state" slow quick \
                >"$runlog" 2>&1
            echo $? >"$fixture/c/run.rc"
        ) &
        engine=$!

        # Wait (bounded) for `quick`'s record to land — then the state is
        # stable until the release file appears, so this read is not a race.
        for _ in $(seq 1 300); do
            grep -q '"recipe_id":"quick"' "$state/index/binpkg.jsonl" 2>/dev/null && break
            sleep 0.05
        done
        grep -q '"recipe_id":"quick"' "$state/index/binpkg.jsonl" 2>/dev/null \
            || fail "quick never registered (its lane must run while slow stalls)" "$runlog"
        mid=$(index_rows "$state" slow | grep -c '"op":"row"')
        [ "$mid" = 2 ] \
            || fail "pruning must DEFER while the slow lane is in flight (guard, §J.4): $mid rows survived"
        [ -f "$old" ] || fail "the in-flight recipe's archive must not be deleted mid-run"

        # Release the lane and settle.
        : >"$release"
        wait "$engine"
        rc=$(cat "$fixture/c/run.rc")
        [ "$rc" = 0 ] || fail "the guarded run is rc 0, got $rc" "$runlog"

        # The deferral was loud and named the recipe.
        grep -F "msg=binpkg_index:_retention_deferred_slow_(lane_in_flight)" "$runlog" >/dev/null \
            || fail "the deferred sweep must announce the in-flight recipe (§I.4)" "$runlog"
        end=$(index_rows "$state" slow | grep -c '"op":"row"')
        [ "$end" = 1 ] \
            || fail "after the lane settles, the sweep converges to the budget (1 slow instance), got $end"
        [ ! -f "$old" ] || fail "the pruned instance's archive must be deleted once swept" "$runlog"
    )
fi

# ─── d. query surfaces: -Qb rows and -Qp probes (§B.3) ─────────────────────
if want d; then
    (
        set -euo pipefail
        ws="$fixture/d/ws"
        state="$fixture/d/state"
        make_workspace "$ws" 1 auto low
        state_ws "$ws"
        export GSA_STATE_DIR="$state"
        add_package "$ws" probe "$gsa_meta_any" git
        run_engine "$ws" -B --no-prefetch --leaf --state-dir "$state" probe
        [ "$FIXTURE_RC" = 0 ] || fail "the probe build is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        archive="$ws/packages/probe/probe-1.0.1-1-any.pkg.tar.zst"

        # `-Qb` rows derive from the records (rule 25(j)); refs filter them.
        run_engine "$ws" -Qb --state-dir "$state"
        row=$(index_rows "$state" probe)
        expected=$(wire_from_record "$row" "$archive")
        [ "$(printf '%s\n' "$FIXTURE_OUTPUT")" = "$expected" ] \
            || fail "-Qb must derive its row from the record + bytes:
want: $expected
got:  $FIXTURE_OUTPUT"
        run_engine "$ws" -Qb --state-dir "$state" probe
        [ "$(printf '%s\n' "$FIXTURE_OUTPUT")" = "$expected" ] \
            || fail "-Qb with a matching ref prints the same row: $FIXTURE_OUTPUT"
        run_engine "$ws" -Qb --state-dir "$state" nonesuch
        [ "$FIXTURE_RC" = 2 ] || fail "an unknown ref is a usage error (§G.1 rc 2), got $FIXTURE_RC"
        vgrep "$FIXTURE_OUTPUT" -i "nonesuch" >/dev/null \
            || fail "the ref refusal names the offender: $FIXTURE_OUTPUT"

        # `-Qp` on a tampered archive: the hash binding fires (§J.4).
        printf 'x' >>"$archive"
        run_engine "$ws" -Qp --state-dir "$state" "$archive"
        [ "$FIXTURE_RC" = 0 ] || fail "-Qp is a report-only query (rc 0), got $FIXTURE_RC"
        vgrep "$FIXTURE_OUTPUT" -F "mismatch" >/dev/null \
            || fail "-Qp must report the tampered archive as a mismatch (§J.4): $FIXTURE_OUTPUT"
        vgrep "$FIXTURE_OUTPUT" -F "hash=disagree size=disagree" >/dev/null \
            || fail "-Qp must report hash/size disagreement: $FIXTURE_OUTPUT"

        # `-Qp` on an unrecorded archive: absent is reported, never guessed.
        stage="$fixture/d/stage"
        stage_pkginfo "$stage" stray stray 9.9.9-1
        stray="$ws/packages/probe/stray-9.9.9-1-any.pkg.tar.zst"
        make_archive "$stray" "$stage"
        run_engine "$ws" -Qp --state-dir "$state" "$stray"
        [ "$FIXTURE_RC" = 0 ] || fail "-Qp on an unrecorded archive is rc 0, got $FIXTURE_RC"
        vgrep "$FIXTURE_OUTPUT" -F "unindexed" >/dev/null \
            || fail "-Qp must report an unrecorded archive as unindexed (§J.4): $FIXTURE_OUTPUT"
        vgrep "$FIXTURE_OUTPUT" -F "hash=unrecorded" >/dev/null \
            || fail "-Qp must not invent agreement for an unrecorded archive: $FIXTURE_OUTPUT"

        # Usage refusals name the argument (§D.1's seam shape, §G.1 rc 2).
        run_engine "$ws" -Qp --state-dir "$state" "$ws/packages/probe/absent.pkg.tar.zst"
        [ "$FIXTURE_RC" = 2 ] || fail "a malformed archive argument is rc 2, got $FIXTURE_RC"
        vgrep "$FIXTURE_OUTPUT" -F "malformed archive argument" >/dev/null \
            || fail "the refusal names the argument: $FIXTURE_OUTPUT"
        run_engine "$ws" -Qp --state-dir "$state"
        [ "$FIXTURE_RC" = 2 ] || fail "-Qp without archives is rc 2, got $FIXTURE_RC"
        vgrep "$FIXTURE_OUTPUT" -F "requires at least one archive" >/dev/null \
            || fail "the refusal says what is missing: $FIXTURE_OUTPUT"
    )
fi

# ─── e. --local-db-check + run-history persistence (§D.1/§H.1/§G) ─────────
if want e; then
    (
        set -euo pipefail
        ws="$fixture/e/ws"
        state="$fixture/e/state"
        make_workspace "$ws" 1 auto low
        state_ws "$ws"
        export GSA_STATE_DIR="$state"
        add_package "$ws" hist "$gsa_meta_any" git

        # A completed run: its machine block and its stored twin (§H.1).
        run_engine "$ws" -B --no-prefetch --leaf --state-dir "$state" hist
        [ "$FIXTURE_RC" = 0 ] || fail "the completed run is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        emitted="$fixture/e/emitted.record"
        printf '%s\n' "$FIXTURE_OUTPUT" |
            sed -n '/^--- run record begin ---$/,/^--- run record end ---$/p' >"$emitted"
        [ -s "$emitted" ] || fail "the run emitted no machine block: $FIXTURE_OUTPUT"

        # The seam verbs: health is clean, runs renders the stored record.
        run_engine "$ws" --local-db-check health
        [ "$FIXTURE_RC" = 0 ] || fail "a clean side-car is rc 0 (§G), got $FIXTURE_RC: $FIXTURE_OUTPUT"
        vgrep "$FIXTURE_OUTPUT" -F "0 finding(s)" >/dev/null \
            || fail "the health summary must report zero findings: $FIXTURE_OUTPUT"
        run_engine "$ws" --local-db-check runs
        [ "$FIXTURE_RC" = 0 ] || fail "the run-history read is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        stored="$fixture/e/stored.record"
        printf '%s\n' "$FIXTURE_OUTPUT" |
            sed -n '/^--- run record begin ---$/,/^--- run record end ---$/p' >"$stored"
        diff -u "$emitted" "$stored" >/dev/null \
            || fail "persistence stores the SAME structure (§H.1), the renderings differ:
$(diff -u "$emitted" "$stored" || true)"

        # An interrupted run: exit 130, full record, stored (§H.1/§K.3).
        # `exec` stays INSIDE the sudo'd chain (W5 §B.10 — the invocation is
        # run_engine's privileged form), so the background pid is the root-
        # owned sudo monitor: the SIGTERM must reach it through the host's
        # REAL sudo (it relays to the engine) and `wait` observes the rc
        # sudo passes through unchanged.
        export GSA_FAKE_STALL_PACKAGE=hist
        export GSA_FAKE_RELEASE_FILE="$fixture/e/never"
        (
            cd "$ws" || exit 1
            fwd=()
            rr2_env_forward fwd
            exec /usr/bin/sudo -n env "${fwd[@]}" "$GSA_TEST_GSA_BIN" -B --no-prefetch --leaf --state-dir "$state" hist \
                >"$fixture/e/interrupt.log" 2>&1
        ) &
        engine=$!
        for _ in $(seq 1 300); do
            [ "$(cat "$GSA_FAKE_COUNT_DIR/hist" 2>/dev/null || echo 0)" = 2 ] && break
            sleep 0.05
        done
        /usr/bin/sudo -n kill -TERM "$engine"
        set +e
        wait "$engine"
        rc=$?
        set -e
        [ "$rc" = 130 ] || fail "an interrupted run exits 130 (§G.1), got $rc" "$fixture/e/interrupt.log"
        sed -n '/^--- run record begin ---$/,/^--- run record end ---$/p' "$fixture/e/interrupt.log" |
            grep -q '^rc: 130$' \
            || fail "the interrupted run emits its full record (§I.4)" "$fixture/e/interrupt.log"

        run_engine "$ws" --local-db-check runs
        [ "$FIXTURE_RC" = 0 ] || fail "the run-history read is rc 0, got $FIXTURE_RC"
        stored="$fixture/e/stored2.record"
        printf '%s\n' "$FIXTURE_OUTPUT" |
            sed -n '/^--- run record begin ---$/,/^--- run record end ---$/p' >"$stored"
        [ "$(grep -c '^--- run record begin ---$' "$stored")" = 2 ] \
            || fail "both runs (completed + interrupted) are in the run history (§H.1):" "$stored"
        sed -n '/^--- run record begin ---$/,/^--- run record end ---$/p' "$fixture/e/interrupt.log" |
            diff -u - <(awk '/^--- run record begin ---$/{n++} n==2' "$stored") >/dev/null \
            || fail "the interrupted record is stored as emitted (§H.1)"

        # A corrupted row is caught BY NAME (§D.1): garble the engine's own
        # index row (truncated JSON, newline kept) and name it in the report.
        row=$(index_rows "$state" hist | head -n 1)
        name=$(basename "$(json_field "$row" archive)")
        garbled=$(printf '%s' "$row" | sed 's/..........$//')
        # the index is engine-owned state (W5 §B.10) — garble it through the
        # host's REAL sudo, never the PATH stub
        awk -v repl="$garbled" '
            /"op":"row"/ && /hist-1\.0\./ { print repl; next }
            { print }
        ' "$state/index/binpkg.jsonl" | /usr/bin/sudo -n tee "$state/index/binpkg.jsonl.tmp" >/dev/null
        /usr/bin/sudo -n mv "$state/index/binpkg.jsonl.tmp" "$state/index/binpkg.jsonl"
        run_engine "$ws" --local-db-check health
        [ "$FIXTURE_RC" = 1 ] || fail "a corrupted row makes the check fail (rc 1), got $FIXTURE_RC: $FIXTURE_OUTPUT"
        vgrep "$FIXTURE_OUTPUT" -E "^corrupt-row index " >/dev/null \
            || fail "the corruption is reported: $FIXTURE_OUTPUT"
        vgrep "$FIXTURE_OUTPUT" -F "$name" >/dev/null \
            || fail "the corrupted row is named ($name): $FIXTURE_OUTPUT"

        # An orphan archive (beside a recipe, no row) is named too.
        stage="$fixture/e/stage"
        stage_pkginfo "$stage" ghost ghost 0.1-1
        make_archive "$ws/packages/hist/ghost-0.1-1-any.pkg.tar.zst" "$stage"
        run_engine "$ws" --local-db-check health
        [ "$FIXTURE_RC" = 1 ] || fail "an orphan archive makes the check fail (rc 1), got $FIXTURE_RC"
        vgrep "$FIXTURE_OUTPUT" -E "^orphan-archive ghost-0.1-1-any.pkg.tar.zst " >/dev/null \
            || fail "the orphan archive is named: $FIXTURE_OUTPUT"

        # Bad usage is rc 2 and names the argument (§D.1).
        run_engine "$ws" --local-db-check bogus
        [ "$FIXTURE_RC" = 2 ] || fail "an unknown verb is rc 2 (§G.1), got $FIXTURE_RC"
        vgrep "$FIXTURE_OUTPUT" -F "unknown argument 'bogus'" >/dev/null \
            || fail "the usage refusal names the argument: $FIXTURE_OUTPUT"
    )
fi

# ─── f. the state-dir override keeps everything inside $TMPDIR (§J.3) ──────
if want f; then
    (
        set -euo pipefail
        ws="$fixture/f/ws"
        state="$fixture/f/state"
        make_workspace "$ws" 1 auto low
        state_ws "$ws"

        # The override is first-class two ways: --state-dir (flag) and
        # GSA_STATE_DIR (env) — flag beats env, and both stay in $TMPDIR.
        export GSA_STATE_DIR="$fixture/f/env-state"
        add_package "$ws" boxed "$gsa_meta_any" git
        run_engine "$ws" -B --no-prefetch --state-dir "$state" boxed
        [ "$FIXTURE_RC" = 0 ] || fail "the --state-dir run is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        [ -f "$state/index/binpkg.jsonl" ] \
            || fail "the flag override must own the state: $state/index/binpkg.jsonl missing"
        [ ! -e "$fixture/f/env-state" ] \
            || fail "--state-dir must beat GSA_STATE_DIR (§J.3): env state was created"

        # env-only: a second workspace whose runs and seam calls carry no
        # --state-dir at all — GSA_STATE_DIR must own its state (§J.3).
        envws="$fixture/f/env-ws"
        make_workspace "$envws" 1 auto low
        state_ws "$envws"
        add_package "$envws" envboxed "$gsa_meta_any" git
        run_engine "$envws" -B --no-prefetch --leaf envboxed
        [ "$FIXTURE_RC" = 0 ] || fail "the env override run is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        [ -f "$fixture/f/env-state/index/binpkg.jsonl" ] \
            || fail "GSA_STATE_DIR must own the state of a flag-less run"
        run_engine "$envws" --local-db-check health
        [ "$FIXTURE_RC" = 0 ] || fail "the env override seam is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        run_engine "$ws" -Qb --state-dir "$state"
        vgrep "$FIXTURE_OUTPUT" -F "boxed|" >/dev/null \
            || fail "-Qb reads the overridden state root: $FIXTURE_OUTPUT"

        # Everything landed inside the fixture tree; /var/lib/gsa is
        # byte-identical to fixture start (asserted again at fixture end).
        varlib_now=$( (find /var/lib/gsa -printf '%p %s %T@\n' 2>/dev/null || true) | sort | md5sum)
        [ "$varlib_now" = "$varlib_before" ] \
            || fail "the real /var/lib/gsa must never move under a fixture (§J.3)"
        [ -d "$state" ] && [ -d "$fixture/f/env-state" ] \
            || fail "both overrides live under the fixture tree"
    )
fi

# ─── the fixture never touched the real state root (§J.3) ──────────────────
varlib_after=$( (find /var/lib/gsa -printf '%p %s %T@\n' 2>/dev/null || true) | sort | md5sum)
[ "$varlib_after" = "$varlib_before" ] \
    || fail "the real /var/lib/gsa changed under tests/gsa-state-v2.sh — fixtures must stay behind --state-dir/GSA_STATE_DIR"
