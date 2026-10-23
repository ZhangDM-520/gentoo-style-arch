#!/usr/bin/env bash
set -euo pipefail

# tests/scheduler-dispatch-order.sh — the `build-tools` dispatch band and the
# closed six-name roster, driven through the NATIVE engine (docs/gsa-contract.md
# §B.4/§C.2/§C.5/§G.1/§H.2/§K.2). Everything here is synthetic: $TMPDIR
# workspaces with stub `makepkg`/`sudo`/`pacman` executables — nothing is
# built for real, no pacman transaction runs, nothing outside the fixture
# tree is written. Expectations are DERIVED from the topology this fixture
# wrote and the run record the run produced (docs/MEMORY.md rule 25(j), the
# tests/gsa-sched-v2.sh edges-file pattern): the dispatch order comes from the
# makepkg stub's own SPAWN/END log, band membership and build-order edges from
# the fixture's own membership/edges files (three-way checked against the
# `gsa -Qt` topology channel and `gsa -Sl @<name>` listings, §B.3/§C.2), and
# the canonical order from the run record's `order:` scalar (§C.5/§H.2) —
# never from pinned prose or counts.
#
# Subject (kept from the fish-era fixture): the sixth group `build-tools` is a
# SCHEDULING CLASS with exactly one behavioural effect: whenever the
# dispatcher picks the next ready package, build-tools members are picked
# BEFORE all other ready packages (§K.2). Build-order edges are stronger
# ALWAYS — the band only reorders packages that are ALREADY ready (topo order /
# prerequisite waits win) — and every other surface keeps topological build
# order: plan, run-record rows/order (a range indexes that order), `-Sl`,
# `--dry-run`. Membership is dual: every build-tools member also carries core,
# so the synthetic members carry 'core,build-tools' — which also pins that the
# loader accepts the name in a comma groups field at all.
#
# Pinned here (fake makepkg/sudo/pacman only; nothing is built or installed):
#   1. roster/loader: membership comes from the topology record alone (§C.2) —
#      `gsa -Qt` group columns and `gsa -Sl @<name>` listings agree with the
#      records this fixture wrote, a dual member is listed in BOTH its groups'
#      selections and deduped in their union (the documented dual count), the
#      roster is CLOSED to the six names, a record naming a seventh group
#      fails the loader (rc 2, §C.2/§G.1) naming the offender, and `@bogusgrp`
#      is an unknown reference (rc 2, §C.1).
#   2. band: a normal package first in topo order and a ready build-tools
#      member after it → the build-tools member is dispatched first.
#   3. edges win: a build-tools member consuming a normal package never
#      STARTS before its slow prerequisite has finished.
#   4. no build-tools member in the set → dispatch order is exactly plan
#      (= topo) order: sets without the group see no behavioural change.
#
# Each scenario is a section wrapped in a ( subshell ) with its own scratch
# workspace under $TMPDIR. GSA_FAKE_SPAWN_LOG captures the dispatch order
# (SPAWN/END timestamps from the fake makepkg) and GSA_FAKE_BUILD_SECONDS
# makes the early-dispatched package slow, so a wrong pick order cannot hide
# behind timing. Exit status, the run record and child-process cleanup are
# asserted on every build scenario.
#
# Flip notes (docs/gsa-fixture-migration.md row `tests/scheduler-dispatch-order.sh`):
# the fish argv retires for the §B grammar: `--list`/`-l` → `gsa -Sl`,
# `-g GRP` → `@GRP` targets (§C.2), `--topology` → `gsa -Qt`, `-n` →
# `-B --dry-run` (§B.8; `gsa -S` would add pacman transactions this scenario
# never pinned), `--no-deps` → `--leaf`. `--no-sync`/`--allow-broken-rustc`
# drop: the §B.9 disposition defers them on a build run and nothing observable
# here depends on them (the synthetic recipes have no version-sync provider;
# measured: the runs pass without the rustc escape hatch). The format: 1 rr_*
# pins become format: 2 rr2_* pins (§H.2 scalar `order` + outcome rows); the
# listing-footer and loader-diagnostic byte pins retire — closed roster and
# dual-count now mean exactly what the topology records, `gsa -Qt` and
# `gsa -Sl @<name>` say about membership. One deviation: the `--dry-run`
# record's `order:` scalar is read by the local `record_order` helper because
# rr2_body (tests/lib/rr-v2.bash, frozen this wave) requires integer
# lanes/normal-jobs/core-jobs scalars and a dry-run record renders them `-`
# (it dispatches nothing and never predicts a plan) — real-run records still
# parse with rr2_*.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"

fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-dispatch-order.XXXXXX")
trap '/usr/bin/sudo -n rm -rf -- "$fixture" 2>/dev/null || rm -rf -- "$fixture" 2>/dev/null || true' EXIT

fail() {
    printf '%s\n' "$1" >&2
    if [ -n "${2:-}" ] && [ -f "$2" ]; then
        sed 's/^/    /' "$2" >&2
    fi
    exit 1
}

# ─── The engine under test: the INSTALLED binary (contract §L.10);
# GSA_TEST_GSA_BIN is the explicit pre-install override (rr-v2.bash) ──────────────────────
if [ -z "${GSA_TEST_GSA_BIN:-}" ]; then
    GSA_TEST_GSA_BIN=$(command -v gsa) || {
        printf 'contract §L.10: no installed gsa on PATH — install gsa-pm, or set GSA_TEST_GSA_BIN explicitly\n' >&2
        exit 1
    }
fi
gsa_bin="$GSA_TEST_GSA_BIN"
[ -x "$gsa_bin" ] || fail "the engine under test is not executable: $gsa_bin"
export GSA_TEST_ENGINE=gsa
export GSA_TEST_GSA_BIN="$gsa_bin"

# ─── Oracle stubs and derivation helpers (inline: §D.2 keeps oracles in the
# fixture that gives them meaning) ──────────────────────────────────────────

# write_dispatch_stub DIR — the oracle makepkg: SPAWN/END nanosecond stamps in
# $GSA_FAKE_SPAWN_LOG (the dispatch-order channel), one sleep from
# $GSA_FAKE_BUILD_SECONDS per build, then the usual trivial archive.
write_dispatch_stub() {
    cat >"$1/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -eu
id=$(basename "$PWD")
printf 'SPAWN %s %s\n' "$id" "$(date +%s%N)" >>"${GSA_FAKE_SPAWN_LOG:?}"
sleep "${GSA_FAKE_BUILD_SECONDS:-0.05}"
printf 'END %s %s\n' "$id" "$(date +%s%N)" >>"${GSA_FAKE_SPAWN_LOG:?}"
: >"$PWD/$id-1.0.0-1-any.pkg.tar.zst"
exit 0
EOF
    chmod +x "$1/bin/makepkg"
}

# listing_rows — the rows of a `-Sl` selection listing (§B.4's `<index>. <id>`
# shape) on stdin, in listing order. Structural: the numbered rows are the
# listing's only row channel; no heading or footer wording is matched.
listing_rows() {
    awk '/^ *[0-9]+\.[ ]/ { print $2 }'
}

# qt_ids / group_members / record_field — the `gsa -Qt` topology channel
# (`id|path|groups|edges|tags`, §B.3), the engine-side surface the fixture
# cross-checks its own membership files against.
qt_ids() {
    awk -F'|' '{ print $1 }' "$1"
}

group_members() { # QT-FILE GROUP — ids whose channel record lists GROUP, sorted
    awk -F'|' -v g="$2" \
        '{ n = split($3, gs, ","); for (i = 1; i <= n; i++) if (gs[i] == g) print $1 }' "$1" | sort
}

record_field() { # QT-FILE ID COLUMN(2=path 3=groups 4=edges 5=tags)
    awk -F'|' -v id="$2" -v col="$3" '$1 == id { print $col }' "$1"
}

# expected_members MEMBERS-FILE GROUP — the ids the fixture wrote as GROUP
# members (MEMBERS-FILE lines are `id groups`, groups comma-listed). This is
# the rule 25(j) derivation source: expectations come from the topology this
# fixture wrote, and the engine surfaces are checked against it.
expected_members() {
    awk -v g="$2" \
        '{ n = split($2, gs, ","); for (i = 1; i <= n; i++) if (gs[i] == g) print $1 }' "$1" | sort
}

# record_order — the `order:` scalar of the run-record block on stdin. WHY NOT
# rr2_scalar: rr2_body (tests/lib/rr-v2.bash, frozen this wave) requires
# integer lanes/normal-jobs/core-jobs scalars, while a `--dry-run` record
# deliberately renders them `-` (it dispatches nothing and never predicts a
# plan). Real-run records still parse with rr2_*; this reads exactly the one
# §H.2 scalar the dry-run block carries (recorded deviation).
record_order() {
    awk '
        /^--- run record begin ---$/ { inb = 1; next }
        /^--- plan ---$/ { exit }
        inb && /^order: / { sub(/^order: /, ""); print; found = 1 }
        END {
            if (!found) {
                print "record_order: no order scalar in the run record" > "/dev/stderr"
                exit 1
            }
        }'
}

spawn_ids() { # $1 = spawn log -> SPAWN ids in dispatch order
    awk '$1 == "SPAWN" { print $2 }' "$1"
}

stamp() { # $1 = log, $2 = SPAWN|END, $3 = id -> nanosecond timestamp
    awk -v kind="$2" -v id="$3" '$1 == kind && $2 == id { print $3; exit }' "$1"
}

assert_clean() { # $1 = workspace, $2 = state dir — children drained, no temp residue
    [ -d "$2" ] || fail "the run of $1 created no state dir $2"
    if ps -eo args= | grep -F "$1" | grep -v grep >/dev/null; then
        printf 'a lane child remained after the run of %s:\n' "$1" >&2
        ps -eo pid=,ppid=,args= | grep -F "$1" | grep -v grep >&2 || true
        exit 1
    fi
    # Atomic publication (§F.2) leaves no temp names; the run's own
    # runs/<run-id>/*.result files are that run's record, not litter.
    if grep < <(find "$2" -name '*.tmp.*' -print -quit) -q .; then
        printf 'a publication temp name remained after the run of %s\n' "$1" >&2
        exit 1
    fi
}

# ─── 1. Roster: -Qt/-Sl agree with the records, roster closed to six ───────
(
    set -euo pipefail
    ws="$fixture/roster/ws"
    make_workspace "$ws" 1 2 low
    add_package "$ws" g1 "$gsa_meta_any" git
    add_package "$ws" s1 "$gsa_meta_any" stable
    add_package "$ws" c1 "$gsa_meta_any" core
    add_package "$ws" m1 "$gsa_meta_any" misc
    add_package "$ws" a1 "$gsa_meta_any" app
    add_package "$ws" t1 "$gsa_meta_any" git
    # Dual membership is the vocabulary: every build-tools member also
    # carries core. This record pins the loader accepts the name in a comma
    # groups field at all.
    set_topology_record "$ws" t1 'core,build-tools' ''
    # The fixture's own membership ground truth (rule 25(j)).
    members="$fixture/roster/members"
    printf 'g1 git\ns1 stable\nc1 core\nm1 misc\na1 app\nt1 core,build-tools\n' >"$members"

    run_engine "$ws" -Qt
    ((FIXTURE_RC == 0)) || fail "gsa -Qt rejects a build-tools topology (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    qt="$fixture/roster/topology-channel.txt"
    printf '%s\n' "$FIXTURE_OUTPUT" >"$qt"
    awk -F'|' 'NF != 5 { exit 1 }' "$qt" \
        || fail "gsa -Qt rows are not id|path|groups|edges|tags:" "$qt"
    [[ $(qt_ids "$qt" | sort | tr '\n' ' ') == "$(awk '{ print $1 }' "$members" | sort | tr '\n' ' ')" ]] \
        || fail "gsa -Qt does not resolve exactly the records this fixture wrote:" "$qt"

    # The roster is CLOSED to six (§C.2): every group name either surface
    # names is one of them, and each is in use — so each @<name> below
    # resolves.
    for name in $(awk -F'|' '{ n = split($3, gs, ","); for (i = 1; i <= n; i++) print gs[i] }' "$qt" | sort -u); do
        case " git stable core misc app build-tools " in
        *" $name "*) ;;
        *) fail "gsa -Qt names group '$name' outside the closed six-name roster:" "$qt" ;;
        esac
    done

    # Membership is the topology record's alone (§C.2): `gsa -Sl @<name>`
    # lists exactly the members the fixture wrote for that group, and the
    # `gsa -Qt` group columns agree. The dual member is listed in BOTH its
    # groups' selections — one package counted in each (the dual count).
    for name in git stable core misc app build-tools; do
        want=$(expected_members "$members" "$name" | tr '\n' ' ')
        [ -n "${want// /}" ] || fail "the roster pin needs a $name member in the fixture's own records:" "$members"
        [[ $(group_members "$qt" "$name" | tr '\n' ' ') == "$want" ]] \
            || fail "gsa -Qt group columns for $name disagree with the fixture's records (want [$want]):" "$qt"
        run_engine "$ws" -Sl "@$name"
        ((FIXTURE_RC == 0)) || fail "gsa -Sl @$name failed (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
        rows=$(listing_rows <<<"$FIXTURE_OUTPUT" | sort | tr '\n' ' ')
        [[ $rows == "$want" ]] \
            || fail "gsa -Sl @$name listed [$rows], want the fixture's $name members [$want]"
    done

    # The dual member counts in BOTH groups above; the union of the two
    # selections dedupes it to exactly one row (one package, two memberships).
    dual=$(comm -12 <(expected_members "$members" core) <(expected_members "$members" build-tools))
    [ -n "$dual" ] && [ "$(printf '%s\n' "$dual" | wc -l)" -eq 1 ] \
        || fail "the fixture must carry exactly one dual core/build-tools member, got [$dual]:" "$members"
    run_engine "$ws" -Sl @build-tools @core
    ((FIXTURE_RC == 0)) || fail "gsa -Sl @build-tools @core failed (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    rows=$(listing_rows <<<"$FIXTURE_OUTPUT" | sort | tr '\n' ' ')
    want=$( (expected_members "$members" build-tools; expected_members "$members" core) | sort -u | tr '\n' ' ')
    [[ $rows == "$want" ]] \
        || fail "the union must dedupe the dual member $dual: rows [$rows], want [$want]"
    [[ $(listing_rows <<<"$FIXTURE_OUTPUT" | grep -cFx "$dual") == 1 ]] \
        || fail "the union lists the dual member $dual more than once: $FIXTURE_OUTPUT"

    # Closed roster, negatives: a seventh group name breaks the loader
    # (rc 2, §C.2/§G.1) naming the offender and the offending group; an
    # unknown @name is a usage error naming the reference (§C.1); a typo is
    # NEVER auto-corrected — it fails naming the nearest candidates.
    bad="$fixture/roster/bad"
    make_workspace "$bad" 1 2 low
    add_package "$bad" bad1 "$gsa_meta_any" git
    set_topology_record "$bad" bad1 'git,bogusgrp' ''
    run_engine "$bad" -Qt
    ((FIXTURE_RC == 2)) \
        || fail "a record naming unknown group bogusgrp must be loader rc 2 (§G.1), got rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
    vgrep "$FIXTURE_OUTPUT" -F 'bad1' >/dev/null \
        || fail "the loader error does not name the offending record: $FIXTURE_OUTPUT"
    vgrep "$FIXTURE_OUTPUT" -F 'bogusgrp' >/dev/null \
        || fail "the loader error does not name the offending group: $FIXTURE_OUTPUT"

    run_engine "$ws" -Sl @bogusgrp
    ((FIXTURE_RC == 2)) \
        || fail "an unknown @group must be usage rc 2 (§C.1/§G.1), got rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
    vgrep "$FIXTURE_OUTPUT" -F '@bogusgrp' >/dev/null \
        || fail "the unknown-reference error does not name the reference: $FIXTURE_OUTPUT"

    run_engine "$ws" -Sl @build-tool
    ((FIXTURE_RC == 2)) \
        || fail "a typo'd @group must be usage rc 2 (§C.1/§G.1), got rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
    vgrep "$FIXTURE_OUTPUT" -F '@build-tools' >/dev/null \
        || fail "the typo error does not report the nearest candidates: $FIXTURE_OUTPUT"
)

# ─── 2. Band: a ready build-tools member is dispatched first ─────────────────
# The plain package precedes the band member in topo order (no edge either
# way: both ready at start) and is deliberately named first — without the band
# the dispatcher picks it. The band member also carries core, so it runs solo
# once picked; the band decides WHICH ready package is picked, never the solo
# rule.
(
    set -euo pipefail
    ws="$fixture/band/ws"
    make_workspace "$ws" 2 2 xhigh
    add_package "$ws" n1 "$gsa_meta_any" git
    add_package "$ws" t1 "$gsa_meta_any" git
    set_topology_record "$ws" t1 'core,build-tools' ''
    write_dispatch_stub "$ws"
    stub_sudo "$ws"
    stub_pacman "$ws"

    export PATH="$ws/bin:$PATH"
    export GSA_CPU_THREADS=24 GSA_MEMORY_GIB=21
    export GSA_FAKE_SPAWN_LOG="$fixture/band/spawn.log"
    export GSA_FAKE_PACMAN_LOG="$fixture/band/pacman.log"
    export GSA_FAKE_BUILD_SECONDS=1

    # The fixture's own topology: one build-tools member (dual with core) and
    # one plain package, no edge — both ready at start (rule 25(j) source).
    members="$fixture/band/members"
    printf 'n1 git\nt1 core,build-tools\n' >"$members"
    band=$(expected_members "$members" build-tools)
    other=$(awk '{ print $1 }' "$members" | grep -vFx "$band" | tr '\n' ' ')
    other=${other% }
    [[ -n $band && -n $other && $band != *" "* && $other != *" "* ]] \
        || fail "the band scenario wants exactly one band member and one plain package:" "$members"
    run_engine "$ws" -Qt
    ((FIXTURE_RC == 0)) || fail "gsa -Qt failed (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    printf '%s\n' "$FIXTURE_OUTPUT" >"$fixture/band/topology-channel.txt"
    [[ $(group_members "$fixture/band/topology-channel.txt" build-tools) == "$band" ]] \
        || fail "gsa -Qt does not report $band as the build-tools member:" "$fixture/band/topology-channel.txt"

    run_engine "$ws" -B --leaf --lanes 2 --intensity xhigh --state-dir "$fixture/band/state" n1 t1
    ((FIXTURE_RC == 0)) || fail "the band run failed (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"

    mapfile -t sp < <(spawn_ids "$GSA_FAKE_SPAWN_LOG")
    [[ ${#sp[@]} == 2 && ${sp[0]:-} == "$band" && ${sp[1]:-} == "$other" ]] \
        || fail "build-tools member $band must be dispatched before ready $other (spawn order: ${sp[*]:-none}, want [$band $other])"

    # The band is dispatch-only: the run-record order stays topological build
    # order (§C.5) with the PLAIN package first — the scenario's falsification
    # condition (if the band member were already first in topo order, the
    # spawn order above would prove nothing about the band).
    order=$(rr2_scalar order <<<"$FIXTURE_OUTPUT")
    [[ $order == "$other $band" ]] \
        || fail "run-record order must stay topological with $other first (want [$other $band]), got: $order"
    [[ $(rr2_outcome "$band" status <<<"$FIXTURE_OUTPUT") == succeeded ]] \
        || fail "$band did not succeed: $(rr2_outcome "$band" <<<"$FIXTURE_OUTPUT")"
    [[ $(rr2_outcome "$other" status <<<"$FIXTURE_OUTPUT") == succeeded ]] \
        || fail "$other did not succeed: $(rr2_outcome "$other" <<<"$FIXTURE_OUTPUT")"
    assert_clean "$ws" "$fixture/band/state"
)

# ─── 3. The band never violates build-order edges ────────────────────────────
# The band member consumes the plain package and is picked first BY THE BAND
# whenever it is ready — but readiness includes the prerequisite's completion,
# so it must not even START before the slow prerequisite has finished, however
# the band is implemented.
(
    set -euo pipefail
    ws="$fixture/edges/ws"
    make_workspace "$ws" 2 2 xhigh
    add_package "$ws" n1 "$gsa_meta_any" git
    add_package "$ws" t1 "$gsa_meta_any" git
    set_topology_record "$ws" t1 'core,build-tools' 'n1'
    write_dispatch_stub "$ws"
    stub_sudo "$ws"
    stub_pacman "$ws"

    export PATH="$ws/bin:$PATH"
    export GSA_CPU_THREADS=24 GSA_MEMORY_GIB=21
    export GSA_FAKE_SPAWN_LOG="$fixture/edges/spawn.log"
    export GSA_FAKE_PACMAN_LOG="$fixture/edges/pacman.log"
    export GSA_FAKE_BUILD_SECONDS=1

    # The fixture's own topology and build-order edge (consumer prereq) — the
    # derivation source for the band member and its prerequisite.
    members="$fixture/edges/members"
    printf 'n1 git\nt1 core,build-tools\n' >"$members"
    edges="$fixture/edges/edges"
    printf 't1 n1\n' >"$edges"
    band=$(expected_members "$members" build-tools)
    pre=$(awk -v c="$band" '$1 == c { print $2 }' "$edges")
    [[ -n $band && -n $pre && $band != *" "* && $pre != *" "* ]] \
        || fail "the edge scenario wants one band member with one prerequisite:" "$members $edges"
    run_engine "$ws" -Qt
    ((FIXTURE_RC == 0)) || fail "gsa -Qt failed (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    qt="$fixture/edges/topology-channel.txt"
    printf '%s\n' "$FIXTURE_OUTPUT" >"$qt"
    [[ $(record_field "$qt" "$band" 4) == "$pre" ]] \
        || fail "gsa -Qt does not report the $band → $pre edge the fixture wrote:" "$qt"

    run_engine "$ws" -B --leaf --lanes 2 --intensity xhigh --state-dir "$fixture/edges/state" n1 t1
    ((FIXTURE_RC == 0)) || fail "the edge run failed (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"

    mapfile -t sp < <(spawn_ids "$GSA_FAKE_SPAWN_LOG")
    [[ ${#sp[@]} == 2 && ${sp[0]:-} == "$pre" && ${sp[1]:-} == "$band" ]] \
        || fail "the band must never violate edges: spawn order ${sp[*]:-none}, want [$pre $band]"
    pre_end=$(stamp "$GSA_FAKE_SPAWN_LOG" END "$pre")
    band_start=$(stamp "$GSA_FAKE_SPAWN_LOG" SPAWN "$band")
    [[ -n $pre_end && -n $band_start ]] \
        || fail "spawn log lacks SPAWN/END stamps: $(tr '\n' ' ' <"$GSA_FAKE_SPAWN_LOG")"
    ((band_start >= pre_end)) \
        || fail "build-tools member $band started ($band_start) before its prerequisite $pre finished ($pre_end)"
    order=$(rr2_scalar order <<<"$FIXTURE_OUTPUT")
    [[ $order == "$pre $band" ]] \
        || fail "run-record order must keep the edge (want [$pre $band]), got: $order"
    [[ $(rr2_outcome "$band" status <<<"$FIXTURE_OUTPUT") == succeeded ]] \
        || fail "$band did not succeed: $(rr2_outcome "$band" <<<"$FIXTURE_OUTPUT")"
    [[ $(rr2_outcome "$pre" status <<<"$FIXTURE_OUTPUT") == succeeded ]] \
        || fail "$pre did not succeed: $(rr2_outcome "$pre" <<<"$FIXTURE_OUTPUT")"
    assert_clean "$ws" "$fixture/edges/state"
)

# ─── 4. No build-tools member: dispatch order is exactly plan order ─────────
# Three plain packages, deliberately requested out of order. One lane keeps
# every spawn sequential so the log order IS the dispatch order. The dry-run
# record order, the run-record order and the observed spawn order must agree
# with each other — sets without the group see no behavioural change at all.
(
    set -euo pipefail
    ws="$fixture/plain/ws"
    make_workspace "$ws" 1 2 xhigh
    for id in p1 p2 p3; do
        add_package "$ws" "$id" "$gsa_meta_any" git
    done
    write_dispatch_stub "$ws"
    stub_sudo "$ws"
    stub_pacman "$ws"

    export PATH="$ws/bin:$PATH"
    export GSA_CPU_THREADS=24 GSA_MEMORY_GIB=21
    export GSA_FAKE_SPAWN_LOG="$fixture/plain/spawn.log"
    export GSA_FAKE_PACMAN_LOG="$fixture/plain/pacman.log"
    export GSA_FAKE_BUILD_SECONDS=0.2

    # Scenario precondition: this set carries no build-tools member (§K.2's
    # band has nothing to reorder here).
    members="$fixture/plain/members"
    printf 'p1 git\np2 git\np3 git\n' >"$members"
    run_engine "$ws" -Qt
    ((FIXTURE_RC == 0)) || fail "gsa -Qt failed (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    qt="$fixture/plain/topology-channel.txt"
    printf '%s\n' "$FIXTURE_OUTPUT" >"$qt"
    [[ -z $(group_members "$qt" build-tools) && -z $(expected_members "$members" build-tools) ]] \
        || fail "the plain scenario must carry no build-tools member:" "$qt"

    run_engine "$ws" -B --dry-run --leaf p2 p1 p3
    ((FIXTURE_RC == 0)) || fail "the plain dry run failed (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    dry=$(record_order <<<"$FIXTURE_OUTPUT") \
        || fail "the dry run emitted no parseable plan order: $FIXTURE_OUTPUT"
    [[ $(printf '%s\n' "$dry" | tr ' ' '\n' | sort | tr '\n' ' ') == "p1 p2 p3 " ]] \
        || fail "the dry run lost a package: [$dry]"
    [[ ! -s $GSA_FAKE_SPAWN_LOG ]] \
        || fail "the dry run dispatched builds: $(tr '\n' ' ' <"$GSA_FAKE_SPAWN_LOG")"

    run_engine "$ws" -B --leaf --lanes 1 --intensity xhigh --state-dir "$fixture/plain/state" p2 p1 p3
    ((FIXTURE_RC == 0)) || fail "the plain run failed (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"

    order=$(rr2_scalar order <<<"$FIXTURE_OUTPUT")
    [[ $order == "$dry" ]] \
        || fail "run-record order [$order] no longer matches the dry-run order [$dry]"
    mapfile -t sp < <(spawn_ids "$GSA_FAKE_SPAWN_LOG")
    spawn=$(printf '%s\n' "${sp[@]:-}" | tr '\n' ' ')
    spawn=${spawn% }
    [[ $spawn == "$dry" ]] \
        || fail "a set with no build-tools members must dispatch in plan order: spawn [$spawn] vs plan [$dry]"
    for id in p1 p2 p3; do
        [[ $(rr2_outcome "$id" status <<<"$FIXTURE_OUTPUT") == succeeded ]] \
            || fail "$id did not succeed: $(rr2_outcome "$id" <<<"$FIXTURE_OUTPUT")"
    done
    assert_clean "$ws" "$fixture/plain/state"
)

printf 'scheduler dispatch order fixture: PASS\n'
