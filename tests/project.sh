#!/usr/bin/env bash
set -euo pipefail

# The builder's package-reference resolution and its two read-only listings.
#
# Resolution accepts four forms, and the two new ones are exact lookups against
# the committed .SRCINFO index (218 distinct pacman names, none shared by two
# recipes), never guesses: a case-variant recipe ID and a pacman package name -
# including a split output - resolve to the recipe that builds them, and each
# substitution is announced. A typo is deliberately NOT auto-corrected: a wrong
# guess would build a whole dependency chain, so it is reported with the nearest
# candidates instead. Measured before the change: `mesa-gti` said only "package
# recipe not found", `zen-browser` (an installed package name) was refused, and
# `-g gti` printed NOTHING at all - resolve_group wrote its diagnostic to a
# stdout the caller was capturing with a command substitution.
#
# The listings are the other half. A range indexes the SELECTION in dependency
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
expected_invocations=20
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
recipes=$(find "$root/packages" -mindepth 3 -maxdepth 3 -name .SRCINFO | wc -l)
[[ $recipes -gt 0 ]] || fail "no recipe .SRCINFO files found under $root/packages"

run -l
require_ok 'the whole-set listing'
all_rows=$(rows | wc -l)
[[ $all_rows -eq $recipes ]] ||
    fail "the whole-set listing has $all_rows rows but there are $recipes recipes"

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

# --- a bare name that grows into a dependency chain says so ----------------
# Growth is DATA (more rows than the named recipe), and --no-deps is exactly
# one row (the note wording lives in the prose section).
run -n niri-spicy-git
require_ok 'the bare name niri-spicy-git'
niri_rows=$(rows | wc -l)
[[ $niri_rows -gt 1 ]] ||
    fail "a bare niri-spicy-git listed $niri_rows row(s) - the dependency chain did not expand"

run -n --no-deps niri-spicy-git
require_ok 'the bare name with --no-deps'
[[ $(rows) == 'niri-spicy-git' ]] ||
    fail "--no-deps niri-spicy-git listed [$(rows | tr '\n' ' ')], not exactly niri-spicy-git"

printf 'cli hints fixture: PASS (%s recipes, %s-row selection indexed, extra forms announced)\n' \
    "$recipes" "$git_rows"

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

# config/ holds exactly the two files the builder reads: topology.conf (THE
# topology source — one record per package, id|path|groups|edges[|tags]) and
# build-defaults.conf. The five-group roster is stated once, in the builder's
# group names; nothing else in config/ is reachable state, so a stray file
# would silently go stale. A run of --list above already proved both files
# load, so only the directory's contents need checking here.
expected_files=(build-defaults.conf topology.conf)
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

printf 'project configuration fixture: PASS\n'
)
