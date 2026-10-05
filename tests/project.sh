#!/usr/bin/env bash
set -euo pipefail

# The builder's package-reference resolution and its two read-only listings.
#
# Resolution accepts four forms, and the two new ones are exact lookups against
# the committed .SRCINFO index (221 distinct pacman names, none shared by two
# recipes), never guesses: a case-variant recipe ID and a pacman package name -
# including a split output - resolve to the recipe that builds them, and each
# substitution is announced. A typo is deliberately NOT auto-corrected: a wrong
# guess would build a whole dependency chain, so it is reported with the nearest
# candidates instead. Measured before the change: `mesa-gti` said only "package
# recipe not found", `zen-browser` (an installed package name) was refused, and
# `-g gti` printed NOTHING at all - resolve_group wrote its diagnostic to a
# stdout the caller was capturing with a command substitution.
#
# The listings are the other half. A range indexes the SELECTION in build
# order, but `--list` printed the whole-set order, so `-l` index 22
# (vscodium-insiders-git) and `-g git 22..24` (ninja-git, mesa-git,
# niri-spicy-git) were different packages with nothing saying so. `-l` now
# honours the selection, and `-n` with no selection covers the whole set, which
# is what --help has always claimed for it.
#
# Read-only: every invocation below is a listing or a dry run.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
builder=$root/build-all.fish
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-cli-hints-fixture.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    printf 'cli hints fixture: %s\n' "$1" >&2
    exit 1
}

out=
rc=0
cache=$tmp/run-cache
mkdir -p "$cache"
# Cache key = the exact argument list, so a replayed call hits the invocation
# that was pre-executed for it.
run_key() { printf '%s\0' "$@" | md5sum | cut -d' ' -f1; }

# Column-0 call syntax is load-bearing: the parallel pre-executor further down
# scrapes THIS FILE with grep -E '^(run|run_split) ' and pre-runs exactly the
# lines that match. Every run/run_split CALL must therefore start at column 0
# (a leading space leaves it unpre-executed and its replay fails with "no
# pre-executed invocation"), and nothing that merely looks like one may start
# there. The scrape count is asserted below.
run() { # [args...] — replay a pre-executed invocation
    local key
    key=$(run_key "$@")
    out=$(cat "$cache/$key.out" 2>/dev/null) ||
        fail "no pre-executed invocation for: $*"
    rc=$(cat "$cache/$key.rc" 2>/dev/null) || rc=127
    [[ $rc =~ ^[0-9]+$ ]] || rc=127
}

out_stdout=
out_stderr=
run_split() { # [args...] — replay with stdout/stderr kept apart. Same column-0
              # call contract as run() above.
    local key
    key=$(run_key "$@")
    out_stdout=$(cat "$cache/$key.out" 2>/dev/null) ||
        fail "no pre-executed invocation for: $*"
    out_stderr=$(cat "$cache/$key.err" 2>/dev/null)
    rc=$(cat "$cache/$key.rc" 2>/dev/null) || rc=127
    [[ $rc =~ ^[0-9]+$ ]] || rc=127
}

require_ok() { # description
    [[ $rc -eq 0 ]] || fail "$1 exited $rc: $out"
}
require_fail() { # description
    [[ $rc -ne 0 ]] || fail "$1 was accepted (it should be refused): $out"
}
require_in() { # description needle
    [[ $out == *"$2"* ]] || fail "$1 does not mention '$2': $out"
}
require_not_in() { # description needle
    [[ $out != *"$2"* ]] || fail "$1 unexpectedly mentions '$2': $out"
}
rows() { # print the numbered rows of $out, as bare package names
    sed -n 's/^ *[0-9][0-9]*\. //p' <<<"$out"
}

# --- parallel pre-execution --------------------------------------------------
# Every run/run_split below is a read-only listing or dry run that has no
# effect on any other, so the calls are collected from THIS FILE and executed
# here concurrently; run()/run_split() then replay them from the cache. The
# assertions stay sequential and byte-for-byte identical — only fish's
# per-invocation startup (config load plus the full map/graph/sort validation
# the loader performs on every call) is paid across all invocations at once
# instead of one after another (~27s -> ~7s).
#
# The scrape is self-pinning: if its match count drifts from the number of
# calls this file actually carries, a call was added/indented without updating
# the expectation below (or a non-call line started imitating one).
expected_invocations=22
scanned_invocations=$(grep -c -E '^(run|run_split) ' "${BASH_SOURCE[0]}")
[[ $scanned_invocations -eq $expected_invocations ]] ||
    fail "self-scan found $scanned_invocations column-0 run/run_split calls, expected $expected_invocations (new calls must start at column 0 and bump this count)"
pids=()
declare -A scheduled=()
while IFS= read -r line; do
    kind=${line%% *}
    rest=${line#* }
    read -r -a argv <<<"$rest"
    ((${#argv[@]})) || continue
    key=$(run_key "${argv[@]}")
    [[ -n ${scheduled[$key]:-} ]] && continue
    scheduled[$key]=1
    if [[ $kind == run_split ]]; then
        (fish "$builder" "${argv[@]}" >"$cache/$key.out" 2>"$cache/$key.err"
        printf '%s\n' "$?" >"$cache/$key.rc") &
    else
        (fish "$builder" "${argv[@]}" >"$cache/$key.out" 2>&1
        printf '%s\n' "$?" >"$cache/$key.rc") &
    fi
    pids+=("$!")
done < <(grep -E '^(run|run_split) ' "${BASH_SOURCE[0]}")
for pid in "${pids[@]}"; do
    wait "$pid" || true
done

# --- unresolved references: refused, with the nearest candidates ------------
run -n --no-deps mesa-gti
require_fail 'the typo mesa-gti'
require_in 'the typo mesa-gti' 'mesa-git'
require_in 'the typo mesa-gti' "build-all.fish -l"

run -n --no-deps mesa
require_fail 'the partial name mesa'
require_in 'the partial name mesa' 'mesa-git'

# A hint is a hint: an unrelated name must not collect one, or the suggestions
# become noise.
run -n --no-deps zzzz
require_fail 'the unrelated name zzzz'
require_not_in 'the unrelated name zzzz' 'Did you mean'

# --- exact extra forms resolve, and say so ---------------------------------
# The substitution announcements themselves are rendering — their wordings
# ('matched recipe … case-sensitive') are pinned once in tests/dashboard.sh's
# prose section; what is pinned here is the RESOLUTION, as rows.
run -n --no-deps MESA-GIT
require_ok 'the case-variant ID MESA-GIT'
[[ $(rows) == 'mesa-git' ]] || fail "MESA-GIT resolved to '$(rows)', not mesa-git"

run -n --no-deps zen-browser
require_ok 'the pacman name zen-browser'
[[ $(rows) == 'zen-browser-pgo' ]] ||
    fail "zen-browser resolved to '$(rows)', not zen-browser-pgo"

# A split output must reach its recipe too - this is the case that would be
# dangerous to guess at, so it is worth pinning.
run -n --no-deps libstdc++-snapshot
require_ok 'the split output libstdc++-snapshot'
require_in 'the split output libstdc++-snapshot' 'gcc-snapshot'
[[ $(rows) == 'gcc-snapshot' ]] ||
    fail "libstdc++-snapshot resolved to '$(rows)', not gcc-snapshot"

# --- the two original forms still resolve, and stay silent -----------------
run -n --no-deps mesa-git
require_ok 'the recipe ID mesa-git'
[[ $(rows) == 'mesa-git' ]] || fail "mesa-git resolved to '$(rows)'"
require_not_in 'the recipe ID mesa-git' 'matched recipe'

run -n --no-deps packages/git/mesa-git
require_ok 'the recipe path packages/git/mesa-git'
[[ $(rows) == 'mesa-git' ]] || fail "the recipe path resolved to '$(rows)'"
require_not_in 'the recipe path packages/git/mesa-git' 'matched recipe'

# --- group and option lookups get the same treatment -----------------------
# The group diagnostic is checked per channel, not just merged: resolve_group's
# stdout is a data channel (the caller captures it with a command
# substitution), so a diagnostic written there is swallowed and the run exits 1
# having said nothing - which is what `-g gti` did before this change. Merging
# the streams would hide that, because the swallowed text leaks into the output
# by another route.
run_split -n -g gti
[[ $rc -ne 0 ]] || fail 'the unknown group gti was accepted (it should be refused)'
[[ $out_stderr == *"unknown group 'gti'"* ]] ||
    fail "the unknown group diagnostic is not on stderr: stdout=[$out_stdout] stderr=[$out_stderr]"
[[ $out_stderr == *"Did you mean 'git'"* ]] ||
    fail "the unknown group diagnostic offers no hint: [$out_stderr]"
[[ $out_stdout != *'unknown group'* ]] ||
    fail "the unknown group diagnostic leaked into stdout: [$out_stdout]"

run --intenstiy max -g git
require_fail 'the mistyped option --intenstiy'
require_in 'the mistyped option --intenstiy' "'--intensity'"

# --- a range indexes the selection, and the listing says which -------------
# The in-scope set is the ENABLED topology records, read through the builder's
# --topology data channel (one reader, one truth — the seam
# tests/srcinfo-freshness.sh and the project configuration section below
# consume), never a second parser of config/ and never a bare .SRCINFO count:
# a count cannot tell an intentional scope exclusion from an accidental
# comment-out. The listing covers exactly the in-scope set; on-disk recipe
# dirs are reconciled against it symmetrically below, so the two sets cannot
# drift and stay "accidentally equal".
run_split --topology
[[ $rc -eq 0 ]] || fail "--topology exited $rc: $out_stderr"
mapfile -t topo_paths < <(grep -v '^#' <<<"$out_stdout" | cut -d'|' -f2 | sort)
[[ ${#topo_paths[@]} -gt 0 ]] || fail "--topology listed no in-scope recipes"

mapfile -t recipe_paths < <(
    cd "$root" || exit 1
    find packages -mindepth 3 -maxdepth 3 -name .SRCINFO |
        sed 's|/\.SRCINFO$||' | sort
)
recipes=${#recipe_paths[@]}
[[ $recipes -gt 0 ]] || fail "no recipe .SRCINFO files found under $root/packages"

# Recipes deliberately out of scope: present on disk WITH their .SRCINFO (so a
# deliberate invocation can still build them) but carrying no enabled topology
# record. This is a decision list, not a parsed one: deriving exclusions from
# `# id|...` comment syntax would make an accidental comment-out look
# sanctioned. Each entry duplicates the dated decision recorded beside the
# commented-out record in config/topology.conf, and every drift between the
# two is loud in exactly one direction (re-enable -> "both excluded and in the
# topology"; drop the entry -> "neither in the topology nor excluded"; add a
# new excluded recipe without an entry -> same).
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

in_scope=${#topo_paths[@]}
run -l
require_ok 'the whole-set listing'
all_rows=$(rows | wc -l)
[[ $all_rows -eq $in_scope ]] ||
    fail "the whole-set listing has $all_rows rows but the topology has $in_scope in-scope recipes ($recipes recipe dirs on disk, ${#excluded_set[@]} excluded)"

run -n
require_ok 'a bare -n'
dry_rows=$(rows | wc -l)
[[ $dry_rows -eq $all_rows ]] ||
    fail "-n with no selection lists $dry_rows packages, --list lists $all_rows"

run -l -g git
require_ok 'the git listing'
git_rows=$(rows | wc -l)
[[ $git_rows -lt $all_rows ]] ||
    fail "-l -g git listed $git_rows packages - the selection was ignored"
# The listing's own rows are the index map (the "Ranges index this list" note
# is rendering, pinned once in tests/dashboard.sh's prose section).
listed_22=$(rows | sed -n '22p')
[[ -n $listed_22 ]] || fail "-l -g git lists $git_rows packages - row 22 is empty"

run -n -g git 22..22
require_ok 'the range -g git 22..22'
[[ $(rows) == "$listed_22" ]] ||
    fail "range index 22 selects '$(rows)' but the listing shows '$listed_22'"

# --- range mistakes are named ---------------------------------------------
run -n -g git 900..950
require_fail 'the out-of-bounds range 900..950'
require_in 'the out-of-bounds range 900..950' "$git_rows-package selection"
require_in 'the out-of-bounds range 900..950' "build-all.fish -l -g git"

run -n -g git 1..999
require_ok 'the over-long range 1..999'
# Clamping is DATA: 1..999 covers the whole selection — exactly $git_rows rows,
# no more (the "clamped" note is rendering, pinned in the prose section).
[[ $(rows | wc -l) -eq $git_rows ]] ||
    fail "1..999 built $(rows | wc -l) packages, not the whole $git_rows-package selection"

run -n -g git ..
require_fail 'the empty range ..'
require_in 'the empty range ..' 'invalid range'

run -n -g git 38..22
require_fail 'the reversed range 38..22'
require_in 'the reversed range 38..22' 'empty'

# --- a bare name grows into its CONSUMERS; a consumer-free one stays single --
# Growth is DATA: the selection of X is X plus its transitive CONSUMERS over
# the topology edges (a record's edges field lists what IT consumes), and
# upstream is never pulled in. --no-deps is exactly one row (the note wording
# lives in the prose section). niri-spicy-git has no consumers in the
# committed topology, so the growth case is glib2-git instead — its
# transitive consumer closure, glib2-git itself listed first. The closure
# SIZE is topology data (22 rows on the 2026-10-03 curated graph, 238 on the
# wired 653-record dependency graph), so the expectation is DERIVED from the
# raw records below — an independent reverse-edge BFS — never a pinned count.
run -n niri-spicy-git
require_ok 'the bare name niri-spicy-git'
niri_rows=$(rows | wc -l)
[[ $niri_rows -eq 1 ]] ||
    fail "a bare niri-spicy-git listed $niri_rows row(s) - it has no consumers, expected exactly 1"
[[ $(rows) == 'niri-spicy-git' ]] ||
    fail "a bare niri-spicy-git listed [$(rows | tr '\n' ' ')], not exactly niri-spicy-git"

run -n --no-deps niri-spicy-git
require_ok 'the bare name with --no-deps'
[[ $(rows) == 'niri-spicy-git' ]] ||
    fail "--no-deps niri-spicy-git listed [$(rows | tr '\n' ' ')], not exactly niri-spicy-git"

run -n glib2-git
require_ok 'the bare name glib2-git'
glib2_expected=$(awk -F'|' -v start=glib2-git '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    { n = split($4, e, ",")
      for (i = 1; i <= n; i++) if (e[i] != "") kids[e[i]] = kids[e[i]] " " $1 }
    END {
        seen[start] = 1
        do {
            changed = 0
            for (x in seen) if (!(x in expanded)) {
                expanded[x] = 1
                m = split(kids[x], ks, " ")
                for (i = 1; i <= m; i++)
                    if (ks[i] != "" && !(ks[i] in seen)) {
                        seen[ks[i]] = 1
                        changed = 1
                    }
            }
        } while (changed)
        for (x in seen) print x
    }' "$root/config/topology.conf" | sort)
glib2_rows=$(rows | wc -l)
glib2_want=$(wc -l <<<"$glib2_expected")
[[ $(rows | sort) == "$glib2_expected" ]] ||
    fail "a bare glib2-git listed $glib2_rows row(s), expected $glib2_want (glib2-git + its transitive consumers over the topology edges): $(comm -3 <(rows | sort) <(printf '%s\n' "$glib2_expected") | head -5 | tr '\n' ' ')"
[[ $(rows | sed -n 1p) == 'glib2-git' ]] ||
    fail "a bare glib2-git does not list glib2-git first: [$(rows | head -3 | tr '\n' ' ')]"

printf 'cli hints fixture: PASS (%s recipes on disk: %s in scope, %s excluded; %s-row selection indexed, extra forms announced)\n' \
    "$recipes" "$in_scope" "${#excluded_set[@]}" "$git_rows"

# ==== version-sync topology tag ====
(
    source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
    fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-version-sync-topology.XXXXXX")
    trap 'rm -rf -- "$fixture"' EXIT

    fail() {
        printf 'version-sync topology fixture: %s\n' "$1" >&2
        exit 1
    }

    ws=$fixture/ws
    make_workspace "$ws" 1 2 low
    add_package "$ws" versioned "$gsa_meta_any" misc
    set_topology_record "$ws" versioned misc '' 'version-sync=nvchecker'

    run_builder fish "$ws/build-all.fish" --topology
    [[ $FIXTURE_RC -eq 0 ]] ||
        fail "the supported version-sync tag was rejected: $FIXTURE_OUTPUT"
    grep -Fqx 'versioned|packages/versioned|misc||version-sync=nvchecker' \
        <<<"$FIXTURE_OUTPUT" ||
        fail "--topology did not round-trip the supported tag: $FIXTURE_OUTPUT"

    run_builder fish "$ws/build-all.fish" --list
    [[ $FIXTURE_RC -eq 0 ]] ||
        fail "--list rejected the supported version-sync tag: $FIXTURE_OUTPUT"

    set_topology_record "$ws" versioned misc '' 'version-sync=unsupported'
    run_builder fish "$ws/build-all.fish" --list
    [[ $FIXTURE_RC -ne 0 ]] ||
        fail "an unsupported version-sync provider was accepted"
    [[ $FIXTURE_OUTPUT == *'unknown tag in topology record versioned: version-sync=unsupported'* ]] ||
        fail "an unsupported provider was not named: $FIXTURE_OUTPUT"

    set_topology_record "$ws" versioned misc '' \
        'version-sync=nvchecker,version-sync=nvchecker'
    run_builder fish "$ws/build-all.fish" --list
    [[ $FIXTURE_RC -ne 0 ]] ||
        fail "a duplicate version-sync tag was accepted"
    [[ $FIXTURE_OUTPUT == *'version-sync=nvchecker appears twice in the tags field of topology record versioned'* ]] ||
        fail "the duplicate version-sync tag was not named: $FIXTURE_OUTPUT"

    printf 'version-sync topology fixture: PASS\n'
)

# ==== project-config.sh ====
(

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

output=$(fish "$root/build-all.fish" --list 2>&1) || {
    printf '%s\n' "$output" >&2
    exit 1
}

if ! grep -F 'xorg-xwayland-git' <<<"$output" >/dev/null; then
    printf 'package listing omitted xorg-xwayland-git:\n%s\n' "$output" >&2
    exit 1
fi

# config/ holds exactly the three files the builder reads: topology.conf (THE
# topology source — one record per package, id|path|groups|edges[|tags]),
# build-defaults.conf, and abi-exclusions.conf (the ABI-drift guard's
# documented exception registry, wired in through read_abi_exclusions — same
# strict-loader contract as topology.conf). The six-group roster is stated
# once, in the builder's group names; nothing else in config/ is reachable
# state, so a stray file would silently go stale. A run of --list above
# already proved all three files load, so only the directory's contents need
# checking here.
expected_files=(abi-exclusions.conf build-defaults.conf topology.conf)
mapfile -t config_files < <(
    find "$root/config" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort
)
if [[ "${config_files[*]}" != "${expected_files[*]}" ]]; then
    printf 'unexpected config/ contents: %s (expected: %s)\n' \
        "${config_files[*]}" "${expected_files[*]}" >&2
    exit 1
fi

# The --topology channel is the data interface tooling consumes: a `# id|...`
# header, then one record per package with ALWAYS five pipe fields
# (id|path|groups|edges|tags; comma-joined lists, empty = none). The channel
# is STDOUT and is captured as such: user fish config can print arbitrary
# noise on stderr (under a foreign fish_function_path it even contains `|`),
# and a data channel must not depend on what the stderr stream carries.
topo=$(fish "$root/build-all.fish" --topology 2>/dev/null)
topo_rc=$?
if ((topo_rc != 0)); then
    printf 'project configuration fixture: --topology failed (rc=%d):\n' "$topo_rc" >&2
    fish "$root/build-all.fish" --topology >/dev/null || true
    exit 1
fi
if [[ ${topo%%$'\n'*} != '# id|path|groups|edges|tags' ]]; then
    printf -- '--topology header is not the pinned shape: %s\n' "${topo%%$'\n'*}" >&2
    exit 1
fi
if ! grep -ve '^#' <<<"$topo" | awk -F'|' 'NF != 5 { exit 1 }'; then
    printf -- '--topology emitted a record without exactly five pipe fields:\n%s\n' \
        "$topo" >&2
    exit 1
fi

sync_ids=$(awk -F'|' 'index("," $5 ",", ",version-sync=nvchecker,") { print $1 }' \
    <<<"$topo" | sort)
expected_sync_ids=$'bettbox\ngcc-snapshot\nzen-browser-pgo'
if [[ $sync_ids != "$expected_sync_ids" ]]; then
    printf 'version-sync topology opt-in is [%s], expected only [%s]\n' \
        "$(tr '\n' ' ' <<<"$sync_ids")" "$(tr '\n' ' ' <<<"$expected_sync_ids")" >&2
    exit 1
fi

printf 'project configuration fixture: PASS\n'
)

# ==== consumer-expansion ====
# Selection of X = X + its transitive CONSUMERS over the topology edges: a
# record's edges field lists what IT consumes, so the consumers of B are the
# records listing B — and upstream is never expanded. The real-topology shape
# is derived above (glib2-git grows into its transitive consumer closure —
# size is topology data, never a pinned count; niri-spicy-git has
# none); this section pins the SEMANTICS synthetically, on a two-hop chain
# x <- c1 <- c2 (c1 consumes x, c2 consumes c1) whose consumers sit in OTHER
# groups than x, plus a consumer-free lone — so every case below can only
# pass when expansion walks the edges in the consumer direction.
(
    source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
    fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-consumer-expansion.XXXXXX")
    trap 'rm -rf -- "$fixture"' EXIT

    fail() {
        printf 'consumer expansion fixture: %s\n' "$1" >&2
        exit 1
    }

    ws=$fixture/ws
    make_workspace "$ws" 1 2 low
    add_package "$ws" x "$gsa_meta_any" git
    add_package "$ws" c1 "$gsa_meta_any" misc
    add_package "$ws" c2 "$gsa_meta_any" core
    add_package "$ws" lone "$gsa_meta_any" git
    set_topology_record "$ws" c1 misc 'x'
    set_topology_record "$ws" c2 core 'c1'
    stub_makepkg "$ws"
    stub_sudo "$ws"
    stub_pacman "$ws"

    dry_rows() { # stdin: a dry-run capture -> its numbered rows, one per line
        sed -n '/Build order (dry run):/,/^Total:/p' | sed -n 's/^ *[0-9][0-9]*\. //p'
    }

    # a. bare X pulls its transitive CONSUMERS (2 hops) in build order, X
    # first — never the upstream chain the old semantics grew into.
    run_builder fish "$ws/build-all.fish" -n x
    [[ $FIXTURE_RC -eq 0 ]] || fail "a: dry run of bare x failed: $FIXTURE_OUTPUT"
    rows_a=$(dry_rows <<<"$FIXTURE_OUTPUT")
    expected_a=$'x\nc1\nc2'
    [[ $rows_a == "$expected_a" ]] ||
        fail "a: bare x listed [$(echo "$rows_a" | tr '\n' ' ')], want [x c1 c2] (transitive consumers in build order, x first)"

    # b. --no-deps is leaf-only: exactly the named package.
    run_builder fish "$ws/build-all.fish" -n --no-deps x
    [[ $FIXTURE_RC -eq 0 ]] || fail "b: dry run of --no-deps x failed: $FIXTURE_OUTPUT"
    rows_b=$(dry_rows <<<"$FIXTURE_OUTPUT")
    [[ $rows_b == x ]] ||
        fail "b: --no-deps x listed [$(echo "$rows_b" | tr '\n' ' ')], want exactly [x]"

    # c. a group selection expands consumers too, even across groups: -g git
    # holds x and lone only, but x's consumers c1 (misc) and c2 (core) must
    # ride in — the chain in build order, lone unordered against it.
    run_builder fish "$ws/build-all.fish" -n -g git
    [[ $FIXTURE_RC -eq 0 ]] || fail "c: dry run of -g git failed: $FIXTURE_OUTPUT"
    rows_c=$(dry_rows <<<"$FIXTURE_OUTPUT")
    set_c=$(printf '%s\n' "$rows_c" | sort | tr '\n' ' ')
    [[ $set_c == 'c1 c2 lone x ' ]] ||
        fail "c: -g git selected [$set_c], want [c1 c2 lone x] (cross-group consumers pulled)"
    [[ $rows_c == *x*c1*c2* ]] ||
        fail "c: the chain is not in build order within [$(echo "$rows_c" | tr '\n' ' ')]"

    # d. a consumer-free selection stays exactly one row.
    run_builder fish "$ws/build-all.fish" -n lone
    [[ $FIXTURE_RC -eq 0 ]] || fail "d: dry run of bare lone failed: $FIXTURE_OUTPUT"
    rows_d=$(dry_rows <<<"$FIXTURE_OUTPUT")
    [[ $rows_d == lone ]] ||
        fail "d: bare lone listed [$(echo "$rows_d" | tr '\n' ' ')], want exactly [lone]"

    # e. continuation idempotence (the tests/resume-command.sh surface): a
    # consumer-expanded run that fails midway hands the run record's remaining
    # set to the resume command, and re-expanding that set must give back
    # exactly the same set — no growth, and no upstream x returning.
    run_builder env \
        PATH="$ws/bin:$PATH" \
        GSA_STATE_DIR="$ws/state" \
        GSA_FAKE_PACMAN_LOG="$ws/pacman.log" \
        GSA_FAKE_FAIL_PACKAGE=c1 \
        GSA_CPU_THREADS=8 \
        GSA_MEMORY_GIB=16 \
        fish "$ws/build-all.fish" --no-sync --allow-broken-rustc x
    [[ $FIXTURE_RC -ne 0 ]] || fail "e: the failing run unexpectedly succeeded: $FIXTURE_OUTPUT"
    [[ $(rr_scalar order <<<"$FIXTURE_OUTPUT") == 'x c1 c2' ]] ||
        fail "e: first run recorded order [$(rr_scalar order <<<"$FIXTURE_OUTPUT")], want [x c1 c2]"
    [[ $(rr_row c1 status <<<"$FIXTURE_OUTPUT") == failed ]] ||
        fail "e: c1 row is not failed: $(rr_row c1 <<<"$FIXTURE_OUTPUT")"
    [[ $(rr_row c2 status <<<"$FIXTURE_OUTPUT") == never-started ]] ||
        fail "e: c2 row is not never-started: $(rr_row c2 <<<"$FIXTURE_OUTPUT")"
    remaining=$(rr_remaining <<<"$FIXTURE_OUTPUT" | tr '\n' ' ')
    remaining=${remaining% }
    [[ $remaining == 'c1 c2' ]] ||
        fail "e: resume set is [$remaining], want [c1 c2]"
    resume_cmd=$(grep '^  build-all\.fish ' <<<"$FIXTURE_OUTPUT" | head -1)
    [[ -n $resume_cmd ]] || fail "e: no resume command in the failure summary: $FIXTURE_OUTPUT"
    [[ "$resume_cmd" == *" $remaining" ]] ||
        fail "e: resume command does not end with the resume set [$remaining]: $resume_cmd"
    [[ $resume_cmd != *--no-deps* ]] ||
        fail "e: resume command invented --no-deps (re-expansion must happen): $resume_cmd"
    resume_args=${resume_cmd#*build-all.fish }
    run_builder env \
        PATH="$ws/bin:$PATH" \
        GSA_STATE_DIR="$ws/state" \
        GSA_FAKE_PACMAN_LOG="$ws/pacman.log" \
        GSA_CPU_THREADS=8 \
        GSA_MEMORY_GIB=16 \
        fish "$ws/build-all.fish" $resume_args
    [[ $FIXTURE_RC -eq 0 ]] || fail "e: the resumed run failed: $FIXTURE_OUTPUT"
    [[ $(rr_scalar order <<<"$FIXTURE_OUTPUT") == 'c1 c2' ]] ||
        fail "e: resume re-expanded to [$(rr_scalar order <<<"$FIXTURE_OUTPUT")], want [c1 c2] (same remaining set — no growth, no upstream x)"
    [[ $(rr_scalar outcome <<<"$FIXTURE_OUTPUT") == success ]] ||
        fail "e: resumed run outcome is not success: $FIXTURE_OUTPUT"

    printf 'consumer expansion fixture: PASS (2-hop chain, cross-group consumer, idempotent continuation)\n'
)

# ==== consumer-expansion-order ====
# The diamond and the duplicate seed pin the ORDER contract of the consumer
# walk (keyed rewrite 2026-10-05): selection of a package grows into its
# transitive consumers, a name reachable twice — or seeded twice — is emitted
# exactly once, and ties in the final build order break on the expansion
# order (record order of the consumer lists). A diamond d <- {m1, m2} <- top
# makes every one of those observable in the dry-run rows: m1 and m2 are
# independent of each other, so their relative order can only come from the
# consumer walk's order.
(
    source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
    fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-consumer-expansion-order.XXXXXX")
    trap 'rm -rf -- "$fixture"' EXIT

    fail() {
        printf 'consumer expansion order fixture: %s\n' "$1" >&2
        exit 1
    }

    ws=$fixture/ws
    make_workspace "$ws" 1 2 low
    add_package "$ws" d "$gsa_meta_any" misc
    add_package "$ws" m1 "$gsa_meta_any" misc
    add_package "$ws" m2 "$gsa_meta_any" misc
    add_package "$ws" top "$gsa_meta_any" misc
    set_topology_record "$ws" m1 misc 'd'
    set_topology_record "$ws" m2 misc 'd'
    set_topology_record "$ws" top misc 'm1,m2'
    stub_makepkg "$ws"
    stub_sudo "$ws"
    stub_pacman "$ws"

    dry_rows() { # stdin: a dry-run capture -> its numbered rows, one per line
        sed -n '/Build order (dry run):/,/^Total:/p' | sed -n 's/^ *[0-9][0-9]*\. //p'
    }

    # a. the diamond expands to exactly four rows: d first, top last, and the
    # two independent middle consumers in record order (m1's record lists d
    # before m2's record does).
    run_builder fish "$ws/build-all.fish" -n d
    [[ $FIXTURE_RC -eq 0 ]] || fail "a: dry run of bare d failed: $FIXTURE_OUTPUT"
    rows_a=$(dry_rows <<<"$FIXTURE_OUTPUT")
    expected_rows=$'d\nm1\nm2\ntop'
    [[ $rows_a == "$expected_rows" ]] ||
        fail "a: bare d listed [$(echo "$rows_a" | tr '\n' ' ')], want [d m1 m2 top] (diamond in build order, record-order tie-break)"

    # b. the same package seeded twice is one selection: identical rows, no
    # doubled member (this is what a misaligned key/name queue would break).
    run_builder fish "$ws/build-all.fish" -n d d
    [[ $FIXTURE_RC -eq 0 ]] || fail "b: dry run of d d failed: $FIXTURE_OUTPUT"
    rows_b=$(dry_rows <<<"$FIXTURE_OUTPUT")
    [[ $rows_b == "$expected_rows" ]] ||
        fail "b: d d listed [$(echo "$rows_b" | tr '\n' ' ')], want the same [d m1 m2 top] (duplicate seed is idempotent)"

    # c. the diamond tip seeded alone stays one row — nothing consumes top,
    # and the upstream diamond is never pulled in.
    run_builder fish "$ws/build-all.fish" -n top
    [[ $FIXTURE_RC -eq 0 ]] || fail "c: dry run of bare top failed: $FIXTURE_OUTPUT"
    rows_c=$(dry_rows <<<"$FIXTURE_OUTPUT")
    [[ $rows_c == top ]] ||
        fail "c: bare top listed [$(echo "$rows_c" | tr '\n' ' ')], want exactly [top] (upstream is never expanded)"

    printf 'consumer expansion order fixture: PASS (diamond, record-order tie-break, duplicate seed)\n'
)
