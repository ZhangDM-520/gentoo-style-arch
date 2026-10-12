#!/usr/bin/env bash
set -euo pipefail

# tests/anchor-defer.sh — ONE unanchorable recipe defers; its dependent parks
# on it, unrelated work still builds, and the resume set is exactly the
# non-succeeded rows. Driven through the NATIVE engine (docs/gsa-contract.md
# §B.5/§B.8, §F.1, §G.1, §H.2–§H.3, §I.3): synthetic $TMPDIR workspaces and a
# stub `makepkg`, no package is built, no pacman transaction runs, nothing
# outside the fixture tree is written. Expectations are DERIVED from the
# fixture's own build-order edges and the run record (docs/MEMORY.md rule
# 25(j) / contract §L.3) — never pinned counts, never prose.
#
# Flip notes (docs/gsa-fixture-migration.md row `tests/anchor-defer.sh`):
# the fish trigger — a mktemp stub failing the ANCHOR scratch of the version
# sync, driven through curl/updpkgsums/mktemp stubs — is fish-only machinery
# and retires. The Phase-2 engine's only deferral path is a makepkg child
# exiting 99 (crates/gsa-build/src/lane.rs:7-10 documents it as the stand-in
# for the fetch/anchoring gates that land with gsa-fetch/version-sync), so
# the deferral is driven by a makepkg stub whose exit 99 is aimed at the
# deferring package. The inventory row's target `deferred 99
# anchoring-refused` is NOT producible today: the named refusal surfaces as
# reason key `source-unfetchable` (§H.3) — a recorded deviation, pinned
# below. The two fish sync-machinery sections (anchor-scratch failure R-F12,
# failed recipe restore R-F21) have no gsa-expressible scenario and retire;
# their "named refusal" meaning re-pins as the reason-key assertion on the
# deferred row. Prose byte-pins (DEFERRED marker, summary log-tail wording,
# 'waits on a deferred package', the resume-command rendering) retire as
# rendering (§L.3): their meanings re-pin from the record. The `blocked`
# spelling retires for `parked` (§H.3 supersedes it, §6 R-4); `--no-deps`
# flips to `--leaf` (§B.8) and the fish builder to `gsa -B` via run_engine;
# fish's non-zero remaps to §G.1's deferral-only 5; the `rr_*` format: 1 pins
# become `rr2_*` (§H.2). `--allow-broken-rustc` and `--no-sync`-era spellings
# drop: nothing here has a version-sync provider or a Rust compile.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"

fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-anchor-defer.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    printf '%s\n' "$1" >&2
    if [ -n "${2:-}" ] && [ -f "$2" ]; then
        sed 's/^/    /' "$2" >&2
    fi
    exit 1
}

# ─── Stub-knob vocabulary (§D.2: declared in the change that adds them) ─────
rr2_stub_knob GSA_FAKE_DEFER_PACKAGE "anchor-defer makepkg stub: package id whose build exits 99 (deferral)"

# ─── The engine under test: built into the fixture tree (scratch only) ──────
cargo build --offline --quiet --target-dir "$fixture/cargo" -p gsa-cli \
    --manifest-path "$gsa_repo_root/Cargo.toml" \
    || fail "cannot build the gsa binary for the fixture"
gsa_bin="$fixture/cargo/debug/gsa"
[ -x "$gsa_bin" ] || fail "cargo did not produce $gsa_bin"
export GSA_TEST_ENGINE=gsa
export GSA_TEST_GSA_BIN="$gsa_bin"

# ─── Derivation helpers (inline oracles: the expectations come from the
# fixture's own edges and the §G.1 rule, never from pinned strings) ──────────

# consumers_closure EDGES-FILE ROOT — the transitive consumer cone of ROOT
# over the fixture's own build-order edges (`consumer prereq` per line), one
# id per line. This is how the parked set is derived.
consumers_closure() {
    awk -v root="$2" '
        { edge[++n] = $1; pre[n] = $2 }
        END {
            seen[root] = 1; queue[1] = root; q = 1
            while (q > 0) {
                cur = queue[q--]
                for (i = 1; i <= n; i++) {
                    if (pre[i] == cur && !(edge[i] in seen)) {
                        seen[edge[i]] = 1; queue[++q] = edge[i]
                    }
                }
            }
            for (k in seen) if (k != root) print k
        }' "$1" | sort
}

# expected_rc POLICY INTERRUPTED — the run exit code §G.1 derives from the
# outcome rows on stdin (usage/refusal are pre-run classes and never appear
# here). The rows are the record's; this function only applies the contract.
expected_rc() {
    awk -v policy="$1" -v interrupted="$2" '
        { counts[$2]++ }
        END {
            if (interrupted == 1) { print 130; exit }
            if (counts["failed"] > 0) { print (policy == "fail-fast") ? 1 : 4; exit }
            if (counts["deferred"] > 0 || counts["parked"] > 0) { print 5; exit }
            print 0
        }'
}

# ─── The scenario: a-stable defers (lane rc 99), b-dep (edge on a-stable)
# parks on it and is never dispatched, c-plain builds — a deferral-only run ──
ws="$fixture/ws"
make_workspace "$ws" 1 2 low
add_package "$ws" a-stable "$gsa_meta_any" stable
add_package "$ws" b-dep "$gsa_meta_any" git
add_package "$ws" c-plain "$gsa_meta_any" git
set_topology_record "$ws" b-dep git 'a-stable'
# the fixture's build-order edges (consumer prereq) — the derivation source
# for the expected park cone and the resume set
edges="$fixture/edges"
printf 'b-dep a-stable\n' >"$edges"

mkdir -p "$ws/fake"
# The scenario makepkg: one call log, then the outcome the knobs name
# (defer 99 for the named package / else ok + archive). The rc-99 build is
# the Phase-2 stand-in for the anchoring gate: a NON-failure deferral (§I.3),
# never a failed build.
cat >"$ws/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
id=$(basename "$PWD")
printf '%s\n' "$id" >>"$GSA_FAKE_DIR/makepkg_calls"
if [ "${GSA_FAKE_DEFER_PACKAGE:-}" = "$id" ]; then exit 99; fi
: >"$PWD/$id-1.0.0-1-any.pkg.tar.zst"
exit 0
EOF
chmod +x "$ws/bin/makepkg"

export PATH="$ws/bin:$PATH"
export GSA_FAKE_DIR="$ws/fake"
export GSA_FAKE_DEFER_PACKAGE=a-stable

run_engine "$ws" -B --leaf --intensity low --state-dir "$ws/state" a-stable b-dep c-plain
{
    echo "$FIXTURE_OUTPUT"
} >"$fixture/output.txt"

# 1. Parked work keeps the run non-zero — §G.1's deferral-only 5 (the fish-era
#    non-zero remaps here), derived from the rows, and the record agrees.
rows=$(rr2_outcome_rows <<<"$FIXTURE_OUTPUT")
expected=$(printf '%s\n' "$rows" | expected_rc cone-stop 0)
[ "$FIXTURE_RC" = "$expected" ] \
    || fail "deferral run rc=$FIXTURE_RC, want $expected (§G.1 from the rows):" "$fixture/output.txt"
[ "$FIXTURE_RC" = 5 ] \
    || fail "a deferral-only run exits 5 (§G.1), got $FIXTURE_RC:" "$fixture/output.txt"
[ "$FIXTURE_RC" = "$(rr2_scalar rc <<<"$FIXTURE_OUTPUT")" ] \
    || fail "the record's rc scalar disagrees with the process exit code:" "$fixture/output.txt"

# 2. a-stable is DEFERRED (never counted as succeeded or failed): rc 99 and
#    the NAMED refusal — the reason key is the engine's naming. This is the
#    named-refusal re-pin of the retired fish sync-machinery sections.
[ "$(rr2_outcome a-stable status <<<"$FIXTURE_OUTPUT")" = "deferred" ] \
    || fail "a-stable is not deferred — a deferral is not a build failure:" "$fixture/output.txt"
[ "$(rr2_outcome a-stable rc <<<"$FIXTURE_OUTPUT")" = "99" ] \
    || fail "a deferral is lane code 99 (§F.1):" "$fixture/output.txt"
[ "$(rr2_outcome a-stable reason <<<"$FIXTURE_OUTPUT")" = "source-unfetchable" ] \
    || fail "the anchoring refusal must name reason key 'source-unfetchable' (§H.3; the engine's rc-99 deferral, the stand-in for the anchoring gate):" "$fixture/output.txt"
if printf '%s\n' "$rows" | awk '$2 == "failed"' | grep -q .; then
    fail "the deferral run recorded a failed row — a deferral never fails the run (§I.3):" "$fixture/output.txt"
fi
if [ -e "$ws/packages/a-stable/a-stable-1.0.0-1-any.pkg.tar.zst" ]; then
    fail "the deferred recipe produced an archive although its build never completed:" "$fixture/output.txt"
fi
[ -f "$ws/packages/a-stable/PKGBUILD" ] \
    || fail "the deferred recipe's PKGBUILD was mutated or disappeared:" "$fixture/output.txt"

# 3. b-dep (edge on a-stable) parks on the deferral and is never dispatched —
#    `parked` + `waits-on-deferred` (§H.3: `blocked` is superseded; §6 R-4).
#    The parked set is derived from the fixture's own edges, never pinned.
cone=$(consumers_closure "$edges" a-stable)
parked=$(printf '%s\n' "$rows" | awk '$2 == "parked" { print $1 }' | sort)
[ "$parked" = "$cone" ] \
    || fail "parked set [$parked] != consumer cone of a-stable [$cone] (derived from $edges):" "$fixture/output.txt"
for pkg in $cone; do
    [ "$(rr2_outcome "$pkg" status <<<"$FIXTURE_OUTPUT")" = "parked" ] \
        || fail "consumer $pkg of the deferral is not parked:" "$fixture/output.txt"
    [ "$(rr2_outcome "$pkg" reason <<<"$FIXTURE_OUTPUT")" = "waits-on-deferred" ] \
        || fail "consumer $pkg must carry waits-on-deferred (§H.3):" "$fixture/output.txt"
done
if grep -qx 'b-dep' "$ws/fake/makepkg_calls" 2>/dev/null; then
    fail "b-dep was dispatched although its prerequisite a-stable was deferred:" "$fixture/output.txt"
fi

# 4. THE POINT: the rest of the dispatch continued — c-plain built.
grep -qx 'c-plain' "$ws/fake/makepkg_calls" 2>/dev/null \
    || fail "c-plain was never built — one deferred recipe stopped the dispatch:" "$fixture/output.txt"
[ -f "$ws/packages/c-plain/c-plain-1.0.0-1-any.pkg.tar.zst" ] \
    || fail "c-plain reports built but produced no archive:" "$fixture/output.txt"
[ "$(rr2_outcome c-plain status <<<"$FIXTURE_OUTPUT")" = "succeeded" ] \
    || fail "unrelated package c-plain did not run to completion:" "$fixture/output.txt"

# 5. The resume set is DATA: the non-succeeded rows in row order — the
#    deferred recipe and its parked consumer, and ONLY those. Derived from
#    the record's `order` filtered through the set the rows imply, then
#    cross-checked against the continuation's own `remaining:` (§H.2); the
#    continuation `command:` restates that set for one owner.
expected_remaining=$(rr2_scalar order <<<"$FIXTURE_OUTPUT" | awk -v want="a-stable $cone" '
    BEGIN { n = split(want, s, " "); for (i = 1; i <= n; i++) keep[s[i]] = 1 }
    { for (i = 1; i <= NF; i++) if ($i in keep) printf("%s ", $i) }' | sed 's/ $//')
remaining_rows=$(rr2_remaining <<<"$FIXTURE_OUTPUT" | tr '\n' ' ' | sed 's/ $//')
[ "$remaining_rows" = "$expected_remaining" ] \
    || fail "resume set [$remaining_rows] is not the deferred recipe plus its consumer cone in row order [$expected_remaining]:" "$fixture/output.txt"
[ "$remaining_rows" = "$(rr2_continuation remaining <<<"$FIXTURE_OUTPUT")" ] \
    || fail "continuation remaining disagrees with the rows-derived resume set [$remaining_rows]:" "$fixture/output.txt"
command=$(rr2_continuation command <<<"$FIXTURE_OUTPUT")
[ -n "$command" ] \
    || fail "the continuation has no command: line for the owner:" "$fixture/output.txt"
for pkg in a-stable $cone; do
    case " $command " in
    *" $pkg "*) ;;
    *) fail "the continuation command does not name resume candidate $pkg: $command" ;;
    esac
done
case $command in
*--leaf*) ;;
*) fail "the continuation command did not mirror --leaf (§H.2): $command" ;;
esac
case $command in
*--intensity*) ;;
*) fail "the continuation command did not mirror the resolved --intensity (§H.2): $command" ;;
esac

printf 'anchor defer fixture: PASS (deferred a-stable, parked b-dep, built c-plain)\n'
