#!/usr/bin/env bash
set -euo pipefail

# tests/project.sh — package-reference resolution, range semantics, consumer
# expansion, strict loader errors and one failing run's continuation
# idempotence, driven through the NATIVE engine (`gsa`, docs/gsa-contract.md
# §B.3-§B.4, §C.1-§C.5, §G.1, §H.2). Real-repo sections are READ-ONLY (`-Sl`,
# `-Qt`, `-B --dry-run`); the synthetic sections build stub packages inside
# $TMPDIR trees only. Expectations are DERIVED (docs/MEMORY.md rule 25(j)):
# selections are compared against the engine's own listing and record
# channels, the consumer closure is computed from `gsa -Qt` rows (never from
# config/), and continuation expectations come from the run record.
#
# Pinned here (one ( subshell ) section per scenario):
#   1. reference resolution — recipe ID, recipe path, case-variant ID
#      (announced), pacman pkgname incl. split outputs (announced); a typo is
#      NEVER auto-corrected: rc 2 naming the reference and the nearest
#      candidates (§C.1), and an unrelated name collects none.
#   2. range semantics — a range indexes the SELECTION in build order and the
#      listing keeps the anchors it addresses (22..22, 22..24, 22.., clamped
#      1..999); a range without a selection anchor is a usage error (§C.3).
#   3. consumer expansion over the committed topology — a selection grows
#      into its transitive CONSUMERS (closure computed from `gsa -Qt` rows)
#      and never into its prerequisites (§C.3).
#   4. the topology channel shape (`gsa -Qt`, five pipe fields, §B.3) and the
#      project configuration reconciliation (config/ contents, in-scope set
#      vs on-disk recipes, version-sync opt-in roster).
#   5. strict loader errors: one broken topology record breaks EVERY command
#      (listing, query, build), rc 2 naming the offending record and line
#      (§C.5/§G.1).
#   6. consumer expansion semantics synthetically (2-hop cross-group chain,
#      leaf-only, group selection, prerequisites never expanded, dry-run plan)
#      plus one failing run's continuation idempotence: the
#      `command:`/`remaining:` pair (§H.2) re-driven through the engine
#      yields the same semantics — the same remaining set, no growth, no
#      upstream return.
#   7. the ORDER contract of the consumer walk: a diamond's independent
#      consumers tie-break on record order, a doubly-seeded name is emitted
#      once, and a tip seeded alone never pulls its upstream in.
#
# Flip notes (docs/gsa-fixture-migration.md row `tests/project.sh`; the row's
# phase cell reads "1 (continuation half at 2)" and the flip is whole-file —
# a fixture drives one engine — so this lands its phase-1 half as well):
#   * argv: fish `--list`/`-l` -> `gsa -Sl`, `--topology` -> `gsa -Qt`, `-n`
#     -> `gsa -B --dry-run`, `--no-deps` -> `--leaf`, `-g git` -> `@git`
#     (§B.3-§B.4/§B.8/§C.2). The deferred spellings `--no-sync` and
#     `--allow-broken-rustc` are DROPPED from the failing/resume scenario:
#     gsa refuses both ("deferred to a later phase", measured) and nothing
#     observable depended on them (no version-sync provider, no rustc probe
#     in the stub workspace); `-s`'s skip surface is another fixture's.
#   * prose: byte-pinned diagnostic wordings retire (gap G9). What is pinned
#     is the meaning: the §G.1 rc class, the offending reference/range/flag
#     being NAMED, and candidate NAMES (§C.1). Substitution-announcement
#     wordings stay rendering (tests/dashboard.sh's prose section); here an
#     announcement is pinned as "the given reference is echoed outside the
#     listing rows" and silence as the reverse.
#   * rr-format1 -> format: 2 (§H.2) through rr2_*: a cone-stop run with a
#     failure exits §G.1's 4 (not 1), and the fish-era `never-started`
#     consumer row becomes `parked … waits-on-failed` (§H.3) — the kept
#     behaviour is that the failure's consumers never build.
#   * gap G4: the engine's DRY-RUN continuations spell `--leaf` as
#     `--leaf=no`/`--leaf=yes` (§H.4's spelling, undefined in §B.8), and gsa
#     accepts both spellings as leaf-only (measured: `gsa -B --leaf=no x`
#     records `selection-source: … leaf=yes`) — a §H.4 continuation replayed
#     verbatim would silently lose expansion. Real-run continuations omit
#     `--leaf` for an expanded run and use bare `--leaf` for a leaf run;
#     those are the §B.8 spellings this fixture pins and re-drives.
#   * rr-v2.bash strictness vs the dry-run record shape: a `--dry-run` record
#     carries `lanes: -`/`normal-jobs: -`/`core-jobs: -`, which rr2_body's
#     integer rule rejects (its strict reading predates the dry-run shape,
#     docs/gsa-fixture-migration.md §8 G12). Dry-run scalars and its
#     continuation are therefore read through the local rr_dry_scalar /
#     rr_dry_cont extractors; real-run records go through rr2_* unchanged.
#   * the fish-era parallel pre-executor (column-0 run/run_split scraping and
#     its self-pin) retires with the fish argv it cached: gsa invocations are
#     cheap and every call now goes through run_engine (tests/lib/rr-v2.bash).
#     The one fish-era stream-split check (a data channel must not carry
#     diagnostics) survives as the gsa-split wrapper below.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"

fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-project.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    printf '%s\n' "$1" >&2
    if [ -n "${2:-}" ] && [ -f "$2" ]; then
        sed 's/^/    /' "$2" >&2
    fi
    exit 1
}

# ─── Stub-knob vocabulary (§D.2: declared here in the change that adds them) ─
rr2_stub_knob GSA_FAKE_STDOUT_LOG "project.sh gsa-split wrapper: pure-stdout capture (stderr sidecar at <log>.err)"

# ─── The engine under test: built into the fixture tree (scratch only) ──────
cargo build --offline --quiet --target-dir "$fixture/cargo" -p gsa-cli \
    --manifest-path "$gsa_repo_root/Cargo.toml" \
    || fail "cannot build the gsa binary for the fixture"
gsa_bin="$fixture/cargo/debug/gsa"
[ -x "$gsa_bin" ] || fail "cargo did not produce $gsa_bin"
export GSA_TEST_ENGINE=gsa
export GSA_TEST_GSA_BIN="$gsa_bin"

# ─── Stream-splitting wrapper: the data-channel purity checks need stdout
# alone. run_engine captures stdout+stderr merged; this wrapper puts the
# engine's pure stdout in $GSA_FAKE_STDOUT_LOG, its stderr in <log>.err, and
# replays both into run_engine's merged capture (all-stdout-then-all-stderr
# order — every assertion through it is presence- or channel-shaped).
gsa_split="$fixture/gsa-split"
cat >"$gsa_split" <<EOF
#!/usr/bin/env bash
set -u
log=\${GSA_FAKE_STDOUT_LOG:?}
"$gsa_bin" "\$@" >"\$log" 2>"\$log.err"
rc=\$?
cat "\$log" "\$log.err"
exit \$rc
EOF
chmod +x "$gsa_split"

# run_split_engine LOG WORKSPACE ARG... — run_engine through gsa-split; the
# engine's stdout lands in LOG, its stderr in LOG.err.
run_split_engine() {
    local log=$1 ws=$2
    shift 2
    local saved_bin=${GSA_TEST_GSA_BIN-} saved_log=${GSA_FAKE_STDOUT_LOG-}
    export GSA_TEST_GSA_BIN="$gsa_split" GSA_FAKE_STDOUT_LOG="$log"
    run_engine "$ws" "$@"
    export GSA_TEST_GSA_BIN="$saved_bin"
    if [ -n "$saved_log" ]; then
        export GSA_FAKE_STDOUT_LOG="$saved_log"
    else
        unset GSA_FAKE_STDOUT_LOG
    fi
}

# ─── Listing/channel readers (inline: the oracles stay where they mean) ─────

# listing_rows / listing_pairs — the `gsa -Sl` index rows of a capture, as
# bare names, or as 'anchor name' pairs. The indices ARE the anchor semantics
# (§C.3: ranges address the listing's rows), so the row rendering is data
# here; header/footer sentences are never pinned (gap G9).
listing_rows() {
    sed -n 's/^ *[0-9][0-9]*\. //p'
}

listing_pairs() {
    sed -n 's/^ *\([0-9][0-9]*\)\. /\1 /p'
}

# nonrow_lines — a listing capture minus its index rows. A substitution
# announcement echoes the GIVEN reference somewhere outside the rows; an
# exact match resolves silently. That presence/absence is the meaning, no
# announcement wording is pinned.
nonrow_lines() {
    awk '!/^ *[0-9]+\. /'
}

# consumers_closure EDGES-FILE ROOT — the transitive consumer cone of ROOT
# over the fixture's own build-order edges (`consumer prereq` per line), one
# id per line: how every expansion expectation is derived.
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

# rr_dry_scalar KEY / rr_dry_cont KEY — one scalar / continuation line of a
# `--dry-run` run record. rr2_body rejects that record shape (see the flip
# notes: `lanes: -` vs its integer rule), so the dry-run record is read
# through these two extractors and pinned on its §H.2 fields; everything
# else in this fixture parses through rr2_*.
rr_dry_scalar() {
    printf '%s\n' "$FIXTURE_OUTPUT" | awk -v key="$1" '
        /^--- run record begin ---$/ { inb = 1; next }
        /^--- plan ---$/ { exit }
        inb {
            p = index($0, ":")
            if (p && substr($0, 1, p - 1) == key) {
                v = substr($0, p + 1); sub(/^ /, "", v); print v; found = 1; exit
            }
        }
        END {
            if (!found) {
                printf("rr_dry_scalar: no %s scalar in the dry-run record\n", key) > "/dev/stderr"
                exit 1
            }
        }'
}

rr_dry_cont() {
    printf '%s\n' "$FIXTURE_OUTPUT" | awk -v key="$1" '
        /^--- continuation ---$/ { p = 1; next }
        /^--- run record end ---$/ { exit }
        p {
            c = index($0, ":")
            if (c && substr($0, 1, c - 1) == key) {
                v = substr($0, c + 1); sub(/^ /, "", v); print v; found = 1; exit
            }
        }
        END {
            if (!found) {
                printf("rr_dry_cont: no %s line in the dry-run continuation\n", key) > "/dev/stderr"
                exit 1
            }
        }'
}

# ─── 1. reference resolution: four exact forms, a typo is never guessed ─────
(
    set -euo pipefail
    root=$gsa_repo_root

    # the candidate names a hint may offer are the topology channel's ids
    # (one reader, one truth — never config/ and never a .SRCINFO count)
    run_split_engine "$fixture/ref-topo.out" "$root" -Qt
    [ "$FIXTURE_RC" = 0 ] || fail "the topology channel failed (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    mapfile -t known_ids < <(awk -F'|' 'NF == 5 { print $1 }' "$fixture/ref-topo.out")
    [ "${#known_ids[@]}" -gt 0 ] || fail "the topology channel listed no records"

    # a typo is reported with the nearest candidates (§C.1) — meaning: the
    # reference is named and the candidate NAMES appear (never a wording)
    run_engine "$root" -Sl --leaf mesa-gti
    [ "$FIXTURE_RC" = 2 ] || fail "the typo mesa-gti must be a usage error (§G.1), got $FIXTURE_RC"
    [[ $FIXTURE_OUTPUT == *'mesa-gti'* ]] ||
        fail "the typo mesa-gti is not named: $FIXTURE_OUTPUT"
    [[ $FIXTURE_OUTPUT == *'mesa-git'* ]] ||
        fail "the typo mesa-gti offers no mesa-git candidate: $FIXTURE_OUTPUT"

    run_engine "$root" -Sl --leaf mesa
    [ "$FIXTURE_RC" = 2 ] || fail "the partial name mesa must be a usage error (§G.1), got $FIXTURE_RC"
    [[ $FIXTURE_OUTPUT == *'mesa-git'* ]] ||
        fail "the partial name mesa offers no mesa-git candidate: $FIXTURE_OUTPUT"

    # a hint is a hint: an unrelated name must not collect one, or the
    # suggestions become noise. Meaning: NO known recipe name is offered.
    run_engine "$root" -Sl --leaf zzzz
    [ "$FIXTURE_RC" = 2 ] || fail "the unrelated name zzzz must be a usage error (§G.1), got $FIXTURE_RC"
    [[ $FIXTURE_OUTPUT == *'zzzz'* ]] ||
        fail "the unrelated name zzzz is not named: $FIXTURE_OUTPUT"
    noise=$(tr -cs 'A-Za-z0-9@._+-' '\n' <<<"$FIXTURE_OUTPUT" | sort -u |
        grep -Fx -f <(printf '%s\n' "${known_ids[@]}" | sort -u) || true)
    [ -z "$noise" ] ||
        fail "the unrelated name zzzz collected candidate(s) [$noise]: $FIXTURE_OUTPUT"

    # a group/set typo gets the same treatment through the @ namespace (§C.2),
    # and its diagnostic stays OFF the data channel (the fish-era bug class:
    # a diagnostic written to a captured stdout is swallowed). Pinned per
    # stream through gsa-split: named on stderr, nothing on stdout.
    run_split_engine "$fixture/ref-gti.out" "$root" -Sl @gti
    [ "$FIXTURE_RC" = 2 ] || fail "the unknown set @gti must be a usage error (§G.1), got $FIXTURE_RC"
    [[ $FIXTURE_OUTPUT == *'@gti'* ]] ||
        fail "the unknown set @gti is not named: $FIXTURE_OUTPUT"
    [[ $FIXTURE_OUTPUT == *'@git'* ]] ||
        fail "the unknown set @gti offers no @git candidate: $FIXTURE_OUTPUT"
    [[ $(cat "$fixture/ref-gti.out") != *'@gti'* ]] ||
        fail "the unknown-set diagnostic leaked onto the stdout data channel: $(cat "$fixture/ref-gti.out")"
    [[ $(cat "$fixture/ref-gti.out.err") == *'@gti'* ]] ||
        fail "the unknown-set diagnostic is not on stderr: $(cat "$fixture/ref-gti.out.err")"

    # exact extra forms resolve (each substitution is announced — the
    # announcement echoes the GIVEN reference outside the rows; its wording
    # is rendering, pinned in tests/dashboard.sh). What is pinned here is
    # the RESOLUTION, as rows.
    run_engine "$root" -Sl --leaf MESA-GIT
    [ "$FIXTURE_RC" = 0 ] || fail "the case-variant ID MESA-GIT was refused: $FIXTURE_OUTPUT"
    [[ $(listing_rows <<<"$FIXTURE_OUTPUT") == 'mesa-git' ]] ||
        fail "MESA-GIT resolved to '$(listing_rows <<<"$FIXTURE_OUTPUT")', not mesa-git"
    [[ $(nonrow_lines <<<"$FIXTURE_OUTPUT") == *'MESA-GIT'* ]] ||
        fail "the case-variant substitution of MESA-GIT is not announced: $FIXTURE_OUTPUT"

    run_engine "$root" -Sl --leaf zen-browser
    [ "$FIXTURE_RC" = 0 ] || fail "the pacman name zen-browser was refused: $FIXTURE_OUTPUT"
    [[ $(listing_rows <<<"$FIXTURE_OUTPUT") == 'zen-browser-pgo' ]] ||
        fail "zen-browser resolved to '$(listing_rows <<<"$FIXTURE_OUTPUT")', not zen-browser-pgo"
    [[ $(nonrow_lines <<<"$FIXTURE_OUTPUT") == *'zen-browser'* ]] ||
        fail "the pkgname substitution of zen-browser is not announced: $FIXTURE_OUTPUT"

    # a split output must reach its recipe too — the case that would be
    # dangerous to guess at
    run_engine "$root" -Sl --leaf libstdc++-snapshot
    [ "$FIXTURE_RC" = 0 ] || fail "the split output libstdc++-snapshot was refused: $FIXTURE_OUTPUT"
    [[ $(listing_rows <<<"$FIXTURE_OUTPUT") == 'gcc-snapshot' ]] ||
        fail "libstdc++-snapshot resolved to '$(listing_rows <<<"$FIXTURE_OUTPUT")', not gcc-snapshot"
    [[ $(nonrow_lines <<<"$FIXTURE_OUTPUT") == *'libstdc++-snapshot'* ]] ||
        fail "the split-output substitution of libstdc++-snapshot is not announced: $FIXTURE_OUTPUT"

    # the two original forms resolve and stay silent (nothing substituted,
    # nothing echoed outside the rows)
    run_engine "$root" -Sl --leaf mesa-git
    [ "$FIXTURE_RC" = 0 ] || fail "the recipe ID mesa-git was refused: $FIXTURE_OUTPUT"
    [[ $(listing_rows <<<"$FIXTURE_OUTPUT") == 'mesa-git' ]] ||
        fail "the recipe ID mesa-git resolved to '$(listing_rows <<<"$FIXTURE_OUTPUT")'"
    [[ $(nonrow_lines <<<"$FIXTURE_OUTPUT") != *'mesa-git'* ]] ||
        fail "the exact recipe ID was not resolved silently: $FIXTURE_OUTPUT"

    run_engine "$root" -Sl --leaf packages/git/mesa-git
    [ "$FIXTURE_RC" = 0 ] || fail "the recipe path packages/git/mesa-git was refused: $FIXTURE_OUTPUT"
    [[ $(listing_rows <<<"$FIXTURE_OUTPUT") == 'mesa-git' ]] ||
        fail "the recipe path resolved to '$(listing_rows <<<"$FIXTURE_OUTPUT")'"
    [[ $(nonrow_lines <<<"$FIXTURE_OUTPUT") != *'packages/git/mesa-git'* ]] ||
        fail "the exact recipe path was not resolved silently: $FIXTURE_OUTPUT"

    # a mistyped option is a usage error naming the flag (§G.1). gsa offers
    # no nearest-flag suggestion (§C.1's candidates cover references only) —
    # the fish-era "'--intensity' hint" pin retires with the prose class.
    run_engine "$root" -B --intenstiy max @git
    [ "$FIXTURE_RC" = 2 ] || fail "the mistyped option --intenstiy must be a usage error (§G.1), got $FIXTURE_RC"
    [[ $FIXTURE_OUTPUT == *'--intenstiy'* ]] ||
        fail "the mistyped option --intenstiy is not named: $FIXTURE_OUTPUT"

    printf 'reference resolution fixture: PASS\n'
)

# ─── 2. a range indexes the selection, and the listing says which ───────────
(
    set -euo pipefail
    root=$gsa_repo_root

    run_engine "$root" -Sl @git
    [ "$FIXTURE_RC" = 0 ] || fail "the @git listing failed: $FIXTURE_OUTPUT"
    git_rows=$(listing_rows <<<"$FIXTURE_OUTPUT" | wc -l)
    [ "$git_rows" -gt 24 ] ||
        fail "-Sl @git lists $git_rows packages - row 22 would not exist"
    git_listing=$FIXTURE_OUTPUT

    run_engine "$root" -Sl
    [ "$FIXTURE_RC" = 0 ] || fail "the whole-set listing failed: $FIXTURE_OUTPUT"
    all_rows=$(listing_rows <<<"$FIXTURE_OUTPUT" | wc -l)
    [ "$git_rows" -lt "$all_rows" ] ||
        fail "-Sl @git listed $git_rows packages - the selection was ignored (whole set is $all_rows)"

    # the listing's own rows are the index map (the "Ranges index this list"
    # note is rendering, gap G9)
    listed_22=$(listing_rows <<<"$git_listing" | sed -n '22p')
    [ -n "$listed_22" ] || fail "-Sl @git lists $git_rows packages - row 22 is empty"

    run_engine "$root" -Sl @git 22..22
    [ "$FIXTURE_RC" = 0 ] || fail "the range @git 22..22 failed: $FIXTURE_OUTPUT"
    [[ $(listing_rows <<<"$FIXTURE_OUTPUT") == "$listed_22" ]] ||
        fail "range index 22 selects '$(listing_rows <<<"$FIXTURE_OUTPUT")' but the listing shows '$listed_22'"
    [[ $(listing_pairs <<<"$FIXTURE_OUTPUT" | cut -d' ' -f1 | paste -sd' ' -) == '22' ]] ||
        fail "range 22..22 did not keep its selection anchor: $FIXTURE_OUTPUT"

    # With a range applied the rows keep their SELECTION anchors — the very
    # numbers the range parser addresses — instead of renumbering from 1
    # (owner directive 2026-10-06), and every anchor carries the SAME name
    # the unfiltered listing pairs it with (owner directive 2026-10-08).
    run_engine "$root" -Sl @git 22..24
    [ "$FIXTURE_RC" = 0 ] || fail "the ranged listing @git 22..24 failed: $FIXTURE_OUTPUT"
    [[ $(listing_pairs <<<"$FIXTURE_OUTPUT" | cut -d' ' -f1 | paste -sd' ' -) == '22 23 24' ]] ||
        fail "ranged -Sl printed anchors '$(listing_pairs <<<"$FIXTURE_OUTPUT" | cut -d' ' -f1 | paste -sd' ' -)' - rows must keep the selection anchors a range addresses"
    want_pairs=$(listing_pairs <<<"$git_listing" | sed -n '22,24p' | paste -sd' ' -)
    [ "$(listing_pairs <<<"$FIXTURE_OUTPUT" | paste -sd' ' -)" = "$want_pairs" ] ||
        fail "ranged -Sl pairs '$(listing_pairs <<<"$FIXTURE_OUTPUT" | paste -sd' ' -)' but the listing pairs anchors 22-24 as '$want_pairs'"

    # the dry-run plan of the same range agrees with the listing: same names
    # at the same anchors, and the record says which range it applied (§H.2
    # selection-source) — one selection, two renderings
    run_engine "$root" -B --dry-run @git 22..24
    [ "$FIXTURE_RC" = 0 ] || fail "the ranged dry run @git 22..24 failed: $FIXTURE_OUTPUT"
    [[ $(rr_dry_scalar selection-source) == 'sets=@git leaf=no range=22..24' ]] ||
        fail "the ranged dry run did not record its selection source: $(rr_dry_scalar selection-source)"
    [[ $(rr_dry_scalar order) == "$(listing_rows <<<"$git_listing" | sed -n '22,24p' | paste -sd' ' -)" ]] ||
        fail "ranged dry-run order [$(rr_dry_scalar order)] but listing anchors 22-24 are [$(listing_rows <<<"$git_listing" | sed -n '22,24p' | paste -sd' ' -)]"

    # one open-ended form end-to-end: N.. runs from its anchor to the end of
    # the selection — numbers and names alike
    run_engine "$root" -Sl @git 22..
    [ "$FIXTURE_RC" = 0 ] || fail "the open-ended range @git 22.. failed: $FIXTURE_OUTPUT"
    want_anchors=$(seq 22 "$git_rows" | paste -sd' ' -)
    [ "$(listing_pairs <<<"$FIXTURE_OUTPUT" | cut -d' ' -f1 | paste -sd' ' -)" = "$want_anchors" ] ||
        fail "open-ended 22.. printed anchors '$(listing_pairs <<<"$FIXTURE_OUTPUT" | cut -d' ' -f1 | paste -sd' ' -)', want '$want_anchors'"
    want_tail=$(listing_rows <<<"$git_listing" | sed -n "22,\$p" | paste -sd' ' -)
    [ "$(listing_rows <<<"$FIXTURE_OUTPUT" | paste -sd' ' -)" = "$want_tail" ] ||
        fail "open-ended 22.. rows '$(listing_rows <<<"$FIXTURE_OUTPUT" | paste -sd' ' -)' but the listing from anchor 22 on is '$want_tail'"

    # range mistakes are named (§G.1 usage class): the offending range, and
    # for an out-of-bounds range the selection size it exceeded
    run_engine "$root" -Sl @git 900..950
    [ "$FIXTURE_RC" = 2 ] || fail "the out-of-bounds range 900..950 must be a usage error (§G.1), got $FIXTURE_RC"
    [[ $FIXTURE_OUTPUT == *'900..950'* ]] ||
        fail "the out-of-bounds range is not named: $FIXTURE_OUTPUT"
    [[ $FIXTURE_OUTPUT == *"1..$git_rows"* ]] ||
        fail "the refusal does not name the $git_rows-package selection's valid range: $FIXTURE_OUTPUT"

    # clamping is DATA: 1..999 covers the whole selection — exactly
    # $git_rows rows (the "clamped" note is rendering, gap G9)
    run_engine "$root" -Sl @git 1..999
    [ "$FIXTURE_RC" = 0 ] || fail "the over-long range 1..999 failed: $FIXTURE_OUTPUT"
    [ "$(listing_rows <<<"$FIXTURE_OUTPUT" | wc -l)" -eq "$git_rows" ] ||
        fail "1..999 selected $(listing_rows <<<"$FIXTURE_OUTPUT" | wc -l) packages, not the whole $git_rows-package selection"

    run_engine "$root" -Sl @git ..
    [ "$FIXTURE_RC" = 2 ] || fail "the empty range .. must be a usage error (§G.1), got $FIXTURE_RC"
    [[ $FIXTURE_OUTPUT == *"'".."'"* ]] ||
        fail "the empty range is not named: $FIXTURE_OUTPUT"

    run_engine "$root" -Sl @git 38..22
    [ "$FIXTURE_RC" = 2 ] || fail "the reversed range 38..22 must be a usage error (§G.1), got $FIXTURE_RC"
    [[ $FIXTURE_OUTPUT == *'38..22'* ]] ||
        fail "the reversed range is not named: $FIXTURE_OUTPUT"

    # the anchor rule (§C.3): a bare range is a usage error — a range never
    # silently selects the whole set
    run_engine "$root" -Sl 22..38
    [ "$FIXTURE_RC" = 2 ] ||
        fail "a bare range must be refused (§C.3: a range needs a selection anchor), got $FIXTURE_RC"

    printf 'range semantics fixture: PASS (%s-package selection indexed)\n' "$git_rows"
)

# ─── 3. consumer expansion over the committed topology (never config/) ─────
(
    set -euo pipefail
    root=$gsa_repo_root

    # the derivation source is the topology channel: id|path|groups|edges|tags
    run_split_engine "$fixture/exp-topo.out" "$root" -Qt
    [ "$FIXTURE_RC" = 0 ] || fail "the topology channel failed (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    exp_edges="$fixture/exp-edges"
    awk -F'|' 'NF == 5 && $4 != "" {
        n = split($4, e, ",")
        for (i = 1; i <= n; i++) if (e[i] != "") print $1, e[i]
    }' "$fixture/exp-topo.out" >"$exp_edges"

    for target in glib2-git niri-spicy-git; do
        # X plus its transitive consumers, derived as a reverse-edge closure
        # over the channel rows; the expected SET is what the graph says
        expected=$( { printf '%s\n' "$target"; consumers_closure "$exp_edges" "$target"; } | sort)

        run_engine "$root" -Sl "$target"
        [ "$FIXTURE_RC" = 0 ] || fail "the listing of $target failed: $FIXTURE_OUTPUT"
        got=$(listing_rows <<<"$FIXTURE_OUTPUT" | sort)
        [ "$got" = "$expected" ] ||
            fail "a bare $target selected [$(printf '%s' "$got" | tr '\n' ' ')], expected [$(printf '%s' "$expected" | tr '\n' ' ')] ($target + its transitive consumers over the topology edges): $(comm -3 <(printf '%s\n' "$got") <(printf '%s\n' "$expected") | head -5 | tr '\n' ' ')"
        [ "$(listing_rows <<<"$FIXTURE_OUTPUT" | sed -n 1p)" = "$target" ] ||
            fail "a bare $target does not list $target first: [$(listing_rows <<<"$FIXTURE_OUTPUT" | head -3 | tr '\n' ' ')]"

        # --leaf suppresses the expansion: exactly the named recipe (§C.3)
        run_engine "$root" -Sl --leaf "$target"
        [ "$FIXTURE_RC" = 0 ] || fail "--leaf $target failed: $FIXTURE_OUTPUT"
        [ "$(listing_rows <<<"$FIXTURE_OUTPUT")" = "$target" ] ||
            fail "--leaf $target listed [$(listing_rows <<<"$FIXTURE_OUTPUT" | tr '\n' ' ')], want exactly [$target]"
    done

    printf 'consumer expansion (committed topology) fixture: PASS (closure derived from gsa -Qt rows)\n'
)

# ─── 4. the topology channel shape and the project configuration ────────────
(
    set -euo pipefail
    root=$gsa_repo_root

    # `gsa -Qt` is THE tooling data channel (§B.3): resolved records,
    # `id|path|groups|edges|tags`, one per line, on STDOUT — captured as
    # such (diagnostics must never corrupt a data channel).
    run_split_engine "$fixture/topo.out" "$root" -Qt
    [ "$FIXTURE_RC" = 0 ] || fail "the topology channel failed (rc=$FIXTURE_RC): $(cat "$fixture/topo.out.err")"
    topo_rows=$(grep -c '' "$fixture/topo.out")
    [ "$topo_rows" -gt 0 ] || fail "the topology channel listed no records"
    if ! awk -F'|' 'NF != 5 { exit 1 }' "$fixture/topo.out"; then
        fail "the topology channel emitted a record without exactly five pipe fields:" "$fixture/topo.out"
    fi

    # The in-scope set is the ENABLED topology records read through the
    # channel (one reader, one truth), never a second parser of config/ and
    # never a bare .SRCINFO count. On-disk recipe dirs are reconciled against
    # it symmetrically, so the two sets cannot drift and stay "accidentally
    # equal".
    mapfile -t topo_paths < <(cut -d'|' -f2 "$fixture/topo.out" | sort)
    mapfile -t recipe_paths < <(
        cd "$root" || exit 1
        find packages -mindepth 3 -maxdepth 3 -name .SRCINFO |
            sed 's|/\.SRCINFO$||' | sort
    )
    recipes=${#recipe_paths[@]}
    [ "$recipes" -gt 0 ] || fail "no recipe .SRCINFO files found under $root/packages"

    # Recipes deliberately out of scope: present on disk WITH their .SRCINFO
    # (so a deliberate invocation can still build them) but carrying no
    # enabled topology record. This is a decision list, not a parsed one:
    # deriving exclusions from `# id|...` comment syntax would make an
    # accidental comment-out look sanctioned. Each entry duplicates the
    # dated decision recorded beside the commented-out record in
    # config/topology.conf, and every drift between the two is loud in
    # exactly one direction (re-enable -> "both excluded and in the
    # topology"; drop the entry -> "neither in the topology nor excluded";
    # add a new excluded recipe without an entry -> same).
    excluded_paths=$'packages/misc/linux-cachyos'

    declare -A topo_set=() recipe_set=() excluded_set=()
    for p in "${topo_paths[@]}"; do topo_set["$p"]=1; done
    for p in "${recipe_paths[@]}"; do recipe_set["$p"]=1; done
    while IFS= read -r p; do
        [[ -n $p ]] && excluded_set["$p"]=1
    done <<<"$excluded_paths"

    for p in "${!excluded_set[@]}"; do
        [[ -n ${recipe_set[$p]:-} ]] ||
            fail "excluded recipe '$p' is not a .SRCINFO-bearing recipe dir - fix the exclusion list"
        [[ -z ${topo_set[$p]:-} ]] ||
            fail "recipe '$p' is both excluded and in the topology - pick one"
    done
    for p in "${topo_paths[@]}"; do
        [[ -n ${recipe_set[$p]:-} ]] ||
            fail "in-scope recipe '$p' has no .SRCINFO - pacman-name resolution would silently miss it"
    done
    unaccounted=()
    for p in "${recipe_paths[@]}"; do
        [[ -n ${topo_set[$p]:-} || -n ${excluded_set[$p]:-} ]] && continue
        unaccounted+=("$p")
    done
    [[ ${#unaccounted[@]} -eq 0 ]] ||
        fail "recipe dirs neither in the topology nor excluded: ${unaccounted[*]} - an accidental comment-out looks exactly like this"

    # config/ holds exactly the three files the engine reads: topology.conf
    # (THE topology source), build-defaults.conf, and abi-exclusions.conf.
    # A `gsa -Sl` run already proved they load; only the directory's contents
    # need checking here.
    expected_files=(abi-exclusions.conf build-defaults.conf topology.conf)
    mapfile -t config_files < <(
        find "$root/config" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort
    )
    [[ "${config_files[*]}" == "${expected_files[*]}" ]] ||
        fail "unexpected config/ contents: ${config_files[*]} (expected: ${expected_files[*]})"

    # the whole-set listing covers exactly the in-scope set
    run_engine "$root" -Sl
    [ "$FIXTURE_RC" = 0 ] || fail "the whole-set listing failed: $FIXTURE_OUTPUT"
    all_rows=$(listing_rows <<<"$FIXTURE_OUTPUT" | wc -l)
    [ "$all_rows" -eq "$topo_rows" ] ||
        fail "the whole-set listing has $all_rows rows but the topology channel has $topo_rows in-scope recipes ($recipes recipe dirs on disk, ${#excluded_set[@]} excluded)"
    listing_rows <<<"$FIXTURE_OUTPUT" | grep -Fx 'xorg-xwayland-git' >/dev/null ||
        fail "the whole-set listing omitted xorg-xwayland-git"

    # version-sync opt-in rides the channel's tags field — the roster the
    # topology records state, ratcheted here so an accidental opt-in is loud
    sync_ids=$(awk -F'|' 'index("," $5 ",", ",version-sync=nvchecker,") { print $1 }' \
        "$fixture/topo.out" | sort)
    expected_sync_ids=$'bettbox\ngcc-snapshot\nzen-browser-pgo'
    [[ $sync_ids == "$expected_sync_ids" ]] ||
        fail "version-sync topology opt-in is [$(tr '\n' ' ' <<<"$sync_ids")], expected [$(tr '\n' ' ' <<<"$expected_sync_ids")]"

    # a build without a selection is a usage error (§B.1: selection is
    # mandatory) — the fish-era bare `-n` whole-set dry run retires; the
    # whole-set listing is `gsa -Sl` above
    run_engine "$root" -B --dry-run
    [ "$FIXTURE_RC" = 2 ] ||
        fail "a bare build must refuse to start (§B.1), got $FIXTURE_RC: $FIXTURE_OUTPUT"

    printf 'topology channel fixture: PASS (%s in-scope, %s excluded; channel rows are 5-field)\n' \
        "$topo_rows" "${#excluded_set[@]}"
)

# ─── 5. strict loader: one broken record breaks every command, rc 2 ────────
(
    set -euo pipefail

    ws="$fixture/loader/ws"
    make_workspace "$ws" 1 2 low
    add_package "$ws" versioned "$gsa_meta_any" misc

    # the line of a record in the loader's source — the loader names it
    record_line() {
        awk -v id="$1" 'index($0, id "|") == 1 { print NR; exit }' "$ws/config/topology.conf"
    }
    assert_refused() { # description record-id expected-needles...
        local desc=$1 what=$2 line needle
        shift 2
        line=$(record_line "$what")
        [ "$FIXTURE_RC" = 2 ] ||
            fail "$desc must break the command as a usage error (§G.1), got $FIXTURE_RC: $FIXTURE_OUTPUT"
        [[ $FIXTURE_OUTPUT == *"config/topology.conf:$line"* ]] ||
            fail "$desc does not name the offending line $line: $FIXTURE_OUTPUT"
        for needle in "$@"; do
            [[ $FIXTURE_OUTPUT == *"$needle"* ]] ||
                fail "$desc does not name '$needle': $FIXTURE_OUTPUT"
        done
    }

    # the supported tag round-trips through the channel (row content shape)
    set_topology_record "$ws" versioned misc '' 'version-sync=nvchecker'
    run_engine "$ws" -Qt
    [ "$FIXTURE_RC" = 0 ] || fail "the supported version-sync tag was rejected: $FIXTURE_OUTPUT"
    grep -Fqx 'versioned|packages/versioned|misc||version-sync=nvchecker' <<<"$FIXTURE_OUTPUT" ||
        fail "-Qt did not round-trip the supported tag: $FIXTURE_OUTPUT"
    run_engine "$ws" -Sl
    [ "$FIXTURE_RC" = 0 ] || fail "-Sl rejected the supported version-sync tag: $FIXTURE_OUTPUT"

    # an unsupported provider is refused naming the record, the tag and line
    set_topology_record "$ws" versioned misc '' 'version-sync=unsupported'
    run_engine "$ws" -Sl
    assert_refused 'an unsupported version-sync provider' versioned \
        'versioned' 'version-sync=unsupported'
    run_engine "$ws" -Qt
    assert_refused 'an unsupported version-sync provider (query path)' versioned \
        'versioned' 'version-sync=unsupported'

    set_topology_record "$ws" versioned misc '' \
        'version-sync=nvchecker,version-sync=nvchecker'
    run_engine "$ws" -Sl
    assert_refused 'a duplicate version-sync tag' versioned \
        'versioned' 'version-sync=nvchecker'

    # a structurally malformed record breaks EVERY command — listing, query
    # and build — naming the offending record and its line (§C.5)
    set_topology_record "$ws" versioned misc ''
    printf 'broken|only-two-fields\n' >>"$ws/config/topology.conf"
    run_engine "$ws" -Sl
    assert_refused 'a malformed topology record (listing)' broken \
        'broken|only-two-fields'
    run_engine "$ws" -Qt
    assert_refused 'a malformed topology record (query)' broken \
        'broken|only-two-fields'
    run_engine "$ws" -B --dry-run versioned
    assert_refused 'a malformed topology record (build)' broken \
        'broken|only-two-fields'

    printf 'strict loader fixture: PASS\n'
)

# ─── 6. consumer expansion semantics + continuation idempotence ─────────────
(
    set -euo pipefail

    ws="$fixture/expansion/ws"
    make_workspace "$ws" 1 2 low
    add_package "$ws" x "$gsa_meta_any" git
    add_package "$ws" c1 "$gsa_meta_any" misc
    add_package "$ws" c2 "$gsa_meta_any" core
    add_package "$ws" lone "$gsa_meta_any" git
    set_topology_record "$ws" c1 misc 'x'
    set_topology_record "$ws" c2 core 'c1'
    # the fixture's build-order edges (consumer prereq) — the derivation
    # source for every expected set below
    edges="$fixture/expansion/edges"
    printf 'c1 x\nc2 c1\n' >"$edges"

    # a. bare X grows into its transitive CONSUMERS (2 hops, other groups),
    # X first — never the upstream chain. Expected set derived from $edges.
    x_expected=$( { printf 'x\n'; consumers_closure "$edges" x; } | sort)
    run_engine "$ws" -Sl x
    [ "$FIXTURE_RC" = 0 ] || fail "a: listing of bare x failed: $FIXTURE_OUTPUT"
    [ "$(listing_rows <<<"$FIXTURE_OUTPUT" | sort)" = "$x_expected" ] ||
        fail "a: bare x selected [$(listing_rows <<<"$FIXTURE_OUTPUT" | sort | tr '\n' ' ')], want [$(printf '%s' "$x_expected" | tr '\n' ' ')] (x + its transitive consumers)"
    [ "$(listing_rows <<<"$FIXTURE_OUTPUT" | sed -n 1p)" = x ] ||
        fail "a: bare x does not list x first: [$(listing_rows <<<"$FIXTURE_OUTPUT" | tr '\n' ' ')]"
    [ "$(listing_rows <<<"$FIXTURE_OUTPUT" | tr '\n' ' ')" = 'x c1 c2 ' ] ||
        fail "a: the chain is not in build order: [$(listing_rows <<<"$FIXTURE_OUTPUT" | tr '\n' ' ')]"

    # b. --leaf is leaf-only: exactly the named package (§C.3)
    run_engine "$ws" -Sl --leaf x
    [ "$FIXTURE_RC" = 0 ] || fail "b: listing of --leaf x failed: $FIXTURE_OUTPUT"
    [ "$(listing_rows <<<"$FIXTURE_OUTPUT")" = x ] ||
        fail "b: --leaf x listed [$(listing_rows <<<"$FIXTURE_OUTPUT" | tr '\n' ' ')], want exactly [x]"

    # c. a group selection expands consumers too, even across groups: @git
    # holds x and lone only, but x's consumers c1 (misc) and c2 (core) ride
    # in — the chain in build order, lone unordered against it
    group_expected=$( {
        printf 'x\nlone\n'
        consumers_closure "$edges" x
    } | sort)
    run_engine "$ws" -Sl @git
    [ "$FIXTURE_RC" = 0 ] || fail "c: listing of @git failed: $FIXTURE_OUTPUT"
    [ "$(listing_rows <<<"$FIXTURE_OUTPUT" | sort)" = "$group_expected" ] ||
        fail "c: @git selected [$(listing_rows <<<"$FIXTURE_OUTPUT" | sort | tr '\n' ' ')], want [$(printf '%s' "$group_expected" | tr '\n' ' ')] (cross-group consumers pulled)"
    [[ $(listing_rows <<<"$FIXTURE_OUTPUT" | tr '\n' ' ') == *x*c1*c2* ]] ||
        fail "c: the chain is not in build order within [$(listing_rows <<<"$FIXTURE_OUTPUT" | tr '\n' ' ')]"

    # d. a consumer-free selection stays exactly one row
    run_engine "$ws" -Sl lone
    [ "$FIXTURE_RC" = 0 ] || fail "d: listing of bare lone failed: $FIXTURE_OUTPUT"
    [ "$(listing_rows <<<"$FIXTURE_OUTPUT")" = lone ] ||
        fail "d: bare lone listed [$(listing_rows <<<"$FIXTURE_OUTPUT" | tr '\n' ' ')], want exactly [lone]"

    # e. prerequisites are NEVER expanded: selecting c2 must not pull the
    # chain it consumes (x, c1) back in
    run_engine "$ws" -Sl c2
    [ "$FIXTURE_RC" = 0 ] || fail "e: listing of bare c2 failed: $FIXTURE_OUTPUT"
    [ "$(listing_rows <<<"$FIXTURE_OUTPUT")" = c2 ] ||
        fail "e: bare c2 listed [$(listing_rows <<<"$FIXTURE_OUTPUT" | tr '\n' ' ')], want exactly [c2] (prerequisites are never expanded)"

    # f. --dry-run renders the plan without building (§B.8): the record
    # carries the selection source, the order, and nothing is built
    run_engine "$ws" -B --dry-run x
    [ "$FIXTURE_RC" = 0 ] || fail "f: dry run of x failed: $FIXTURE_OUTPUT"
    [ "$(rr_dry_scalar format)" = 2 ] || fail "f: dry-run record is not format 2: $FIXTURE_OUTPUT"
    [ "$(rr_dry_scalar selection-source)" = 'sets=x leaf=no range=-' ] ||
        fail "f: unexpected selection source: $(rr_dry_scalar selection-source)"
    [ "$(rr_dry_scalar order)" = 'x c1 c2' ] ||
        fail "f: dry-run order is [$(rr_dry_scalar order)], want [x c1 c2]"
    [ "$(rr_dry_scalar outcome)" = planned ] ||
        fail "f: a dry run must record outcome 'planned': $FIXTURE_OUTPUT"
    [ "$(rr_dry_scalar rc)" = 0 ] || fail "f: a dry run exits 0: $FIXTURE_OUTPUT"
    [[ $(rr_dry_cont command) == *'--dry-run'* ]] ||
        fail "f: the dry-run continuation does not mirror --dry-run (§H.2): $(rr_dry_cont command)"
    [ "$(rr_dry_cont remaining)" = 'x c1 c2' ] ||
        fail "f: dry-run remaining [$(rr_dry_cont remaining)] != its rows [x c1 c2]"
    if find "$ws/packages" -name '*.pkg.tar.zst' -print -quit | grep -q .; then
        fail "f: --dry-run built an archive (it must never build)"
    fi

    # g. one failing run's continuation idempotence (the resume surface): a
    # consumer-expanded run that fails midway parks its cone and hands the
    # record's remaining set to the continuation; re-driving `command:`
    # itself must give back exactly the same semantics — no growth, no
    # upstream x returning.
    stub_makepkg "$ws"
    export PATH="$ws/bin:$PATH"
    export GSA_STATE_DIR="$fixture/expansion/state"
    export GSA_FAKE_FAIL_PACKAGE=c1
    run_engine "$ws" -B --intensity low x
    unset GSA_FAKE_FAIL_PACKAGE
    g_output=$FIXTURE_OUTPUT
    printf '%s\n' "$g_output" >"$fixture/expansion/first.txt"
    [ "$FIXTURE_RC" = 4 ] ||
        fail "g: a cone-stop run with a failure exits 4 (§G.1), got $FIXTURE_RC:" "$fixture/expansion/first.txt"
    [ "$FIXTURE_RC" = "$(rr2_scalar rc <<<"$g_output")" ] ||
        fail "g: the record's rc scalar disagrees with the process exit code:" "$fixture/expansion/first.txt"
    [ "$(rr2_scalar outcome <<<"$g_output")" = failed ] ||
        fail "g: a cone-stop run with a failure must record outcome 'failed':" "$fixture/expansion/first.txt"
    [ "$(rr2_scalar order <<<"$g_output")" = 'x c1 c2' ] ||
        fail "g: first run recorded order [$(rr2_scalar order <<<"$g_output")], want [x c1 c2]"
    [ "$(rr2_outcome x status <<<"$g_output")" = succeeded ] ||
        fail "g: x did not run to completion:" "$fixture/expansion/first.txt"
    [ "$(rr2_outcome c1 status <<<"$g_output")" = failed ] ||
        fail "g: c1 row is not failed: $(rr2_outcome c1 <<<"$g_output")"
    [ "$(rr2_outcome c1 rc <<<"$g_output")" = 1 ] ||
        fail "g: a build failure is lane code 1 (§F.1): $(rr2_outcome c1 <<<"$g_output")"
    # the failure's consumer never builds — §H.3 parks it (the fish-era
    # `never-started` row; the kept behaviour is that nothing of c2 was built)
    [ "$(rr2_outcome c2 status <<<"$g_output")" = parked ] ||
        fail "g: the consumer of the failure must park (§I.1): $(rr2_outcome c2 <<<"$g_output")"
    [ "$(rr2_outcome c2 reason <<<"$g_output")" = waits-on-failed ] ||
        fail "g: the parked consumer must carry waits-on-failed (§H.3): $(rr2_outcome c2 <<<"$g_output")"

    remaining=$(rr2_remaining <<<"$g_output" | paste -sd' ' -)
    [ "$remaining" = 'c1 c2' ] ||
        fail "g: resume set is [$remaining], want [c1 c2]"
    [ "$remaining" = "$(rr2_continuation remaining <<<"$g_output")" ] ||
        fail "g: continuation remaining [$(rr2_continuation remaining <<<"$g_output")] != rows-derived [$remaining]"

    cmd=$(rr2_continuation command <<<"$g_output")
    [ -n "$cmd" ] || fail "g: no continuation command in the record:" "$fixture/expansion/first.txt"
    # §H.2's flag-rule table mirrors the resolved parallelism values as
    # explicit flags and warns about environment inputs rather than baking
    # them in; a non-leaf run mirrors no --leaf at all (§B.8's spelling) so
    # the replay re-expands (gap G4: the engine's DRY-RUN continuations use
    # the undefined `--leaf=no` form — see the flip notes)
    [[ $cmd == *"--intensity $(rr2_scalar intensity <<<"$g_output")"* ]] ||
        fail "g: the continuation does not mirror the resolved intensity: $cmd"
    [[ $cmd == *"--lanes $(rr2_scalar lanes <<<"$g_output")"* ]] ||
        fail "g: the continuation does not mirror the resolved lanes: $cmd"
    [[ $cmd == *'--jobs '* ]] ||
        fail "g: the continuation does not mirror the resolved jobs: $cmd"
    [[ $cmd != *'--leaf'* ]] ||
        fail "g: the continuation of an expanded run must carry no --leaf (the replay must re-expand): $cmd"
    [[ $cmd != *"$GSA_STATE_DIR"* ]] ||
        fail "g: the continuation baked the state dir in instead of warning (§H.2): $cmd"
    rr2_continuation env-required <<<"$g_output" | tr ' ' '\n' | grep -Fx GSA_STATE_DIR >/dev/null ||
        fail "g: the ambient GSA_STATE_DIR is not warned about (§H.2 env-required): $(rr2_continuation env-required <<<"$g_output")"
    [[ $cmd == *" $remaining" ]] ||
        fail "g: the continuation command does not end with the remaining set [$remaining]: $cmd"

    # re-drive the continuation's command: itself (translated to the current
    # engine argv) — same semantics: the same set, no growth, no upstream x
    read -ra cmd_argv <<<"${cmd#gsa }"
    run_engine "$ws" "${cmd_argv[@]}"
    r_output=$FIXTURE_OUTPUT
    printf '%s\n' "$r_output" >"$fixture/expansion/resume.txt"
    [ "$FIXTURE_RC" = 0 ] ||
        fail "g: the re-driven continuation failed: $FIXTURE_RC:" "$fixture/expansion/resume.txt"
    [ "$(rr2_scalar outcome <<<"$r_output")" = success ] ||
        fail "g: the re-driven run's outcome is not success: $(rr2_scalar outcome <<<"$r_output")"
    [ "$(rr2_scalar order <<<"$r_output")" = 'c1 c2' ] ||
        fail "g: the continuation re-expanded to [$(rr2_scalar order <<<"$r_output")], want [c1 c2] (same remaining set — no growth, no upstream x)"
    [ -z "$(rr2_remaining <<<"$r_output")" ] ||
        fail "g: the resumed run left rows: $(rr2_remaining <<<"$r_output" | paste -sd' ' -)"

    printf 'consumer expansion (synthetic chain) fixture: PASS (2-hop chain, cross-group consumer, dry-run plan, idempotent continuation)\n'
)

# ─── 7. consumer expansion ORDER: diamond, duplicate seed, tip alone ────────
(
    set -euo pipefail

    ws="$fixture/expansion-order/ws"
    make_workspace "$ws" 1 2 low
    add_package "$ws" d "$gsa_meta_any" misc
    add_package "$ws" m1 "$gsa_meta_any" misc
    add_package "$ws" m2 "$gsa_meta_any" misc
    add_package "$ws" top "$gsa_meta_any" misc
    set_topology_record "$ws" m1 misc 'd'
    set_topology_record "$ws" m2 misc 'd'
    set_topology_record "$ws" top misc 'm1,m2'
    edges="$fixture/expansion-order/edges"
    printf 'm1 d\nm2 d\ntop m1\ntop m2\n' >"$edges"

    # the diamond expands to exactly four rows: d first, top last, and the
    # two independent middle consumers in record order (m1's record lists d
    # before m2's record does — the tie-break is the expansion order)
    diamond_expected=$( { printf 'd\n'; consumers_closure "$edges" d; } | sort)
    run_engine "$ws" -Sl d
    [ "$FIXTURE_RC" = 0 ] || fail "a: listing of bare d failed: $FIXTURE_OUTPUT"
    [ "$(listing_rows <<<"$FIXTURE_OUTPUT" | sort)" = "$diamond_expected" ] ||
        fail "a: bare d selected [$(listing_rows <<<"$FIXTURE_OUTPUT" | sort | tr '\n' ' ')], want [$(printf '%s' "$diamond_expected" | tr '\n' ' ')]"
    [ "$(listing_rows <<<"$FIXTURE_OUTPUT" | tr '\n' ' ')" = 'd m1 m2 top ' ] ||
        fail "a: bare d listed [$(listing_rows <<<"$FIXTURE_OUTPUT" | tr '\n' ' ')], want [d m1 m2 top] (diamond in build order, record-order tie-break)"

    # the same package seeded twice is one selection: identical rows, no
    # doubled member (this is what a misaligned key/name queue would break)
    run_engine "$ws" -Sl d d
    [ "$FIXTURE_RC" = 0 ] || fail "b: listing of d d failed: $FIXTURE_OUTPUT"
    [ "$(listing_rows <<<"$FIXTURE_OUTPUT" | tr '\n' ' ')" = 'd m1 m2 top ' ] ||
        fail "b: d d listed [$(listing_rows <<<"$FIXTURE_OUTPUT" | tr '\n' ' ')], want the same [d m1 m2 top] (duplicate seed is idempotent)"

    # the diamond tip seeded alone stays one row — nothing consumes top, and
    # the upstream diamond is never pulled in (prerequisites never expand)
    run_engine "$ws" -Sl top
    [ "$FIXTURE_RC" = 0 ] || fail "c: listing of bare top failed: $FIXTURE_OUTPUT"
    [ "$(listing_rows <<<"$FIXTURE_OUTPUT")" = top ] ||
        fail "c: bare top listed [$(listing_rows <<<"$FIXTURE_OUTPUT" | tr '\n' ' ')], want exactly [top] (upstream is never expanded)"

    printf 'consumer expansion order fixture: PASS (diamond, record-order tie-break, duplicate seed)\n'
)
