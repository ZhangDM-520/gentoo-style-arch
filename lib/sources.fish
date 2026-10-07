# lib/sources.fish — Design C leaf module: PKGBUILD/.SRCINFO parsing, version
# sync, VCS-freshness and checksum anchoring. Extracted verbatim from
# build-all.fish (2026-10-05, Design C minimal modular split): function names
# and behaviour are unchanged; the entry sources this file before
# load_project_config and the hidden seam blocks, so every caller sees the
# same flat fish function namespace as before the split.
#
# Interface: the functions themselves, plus these out-param globals (set here,
# read by the scheduler core in build-all.fish):
#   _VCS_REVISION_ERROR       non-empty = last VCS revision resolution failed
#                             (record_vcs_archive_revisions, vcs_archive_is_current)
#   _VCS_SKIP_TOLERANCE       resolved skip tolerance (vcs_skip_tolerance_resolve)
#   _FRESHNESS_WAIVER         '1' = freshness waived despite stale inputs
#   _FRESHNESS_WAIVER_REASON  the waiver's reason token (vcs_archive_is_current)
#   _DEFER_REASON             set to 'source-unfetchable' by anchor_sums_from_provider
#   _VERSION_SYNC_TMP_ERROR   reason a safe temp dir could not be made
#                             (version_sync_temp_dir, rc 2)
#   _SR_ROWS / _PB_ROWS       memoised shared-parse caches (srcinfo_rows,
#                             pkgbuild_scan_rows) — cross-module read-only
#   _VCS_ABI_ADVANCE_WINDOW   advance-window constant (vcs_git_advance_distance)
#   _SRCINFO_EXTRA_SOURCES    provider-only sources after a successful
#                             srcinfo_matches_sources (reported, never anchored)
# Reads from the entry (documented coupling, unchanged): _PACKAGE_MAP,
# _SCRIPT_DIR-derived paths, _STATE_DIR, synced.list state, ui_* printers.

# Read PKGBUILD scalars through Bash like arrays; values may depend on earlier
# shell assignments.
function pkgbuild_var -a pkg_path var
    bash -c '
        [[ $2 =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || exit 2
        __gsa_pkgbuild_var_name=$2
        readonly __gsa_pkgbuild_var_name
        cd "$1" || exit 1
        source ./PKGBUILD >/dev/null 2>&1 || exit $?
        declare -p "$__gsa_pkgbuild_var_name" >/dev/null 2>&1 || exit 0
        printf "%s\n" "${!__gsa_pkgbuild_var_name}"
    ' _ "$pkg_path" "$var" 2>/dev/null
end

# Read the archive-selection version pair once; makepkg writes pkgver()'s
# resolved value back to PKGBUILD, which keeps discovery aligned with its
# archive. pkgver comes back as makepkg builds it INTO THE FILENAME
# (`get_full_version`: `epoch:pkgver`) — an epoch-bearing recipe archives as
# ninja-git-2:1.13.…-1-x86_64.pkg.tar.zst and a bare pkgver never matches that
# name (2026-10-06 full-build finding; 47 recipes carry epoch=).
function pkgbuild_version -a pkg_path
    bash -c '
        cd "$1" || exit 1
        source ./PKGBUILD >/dev/null 2>&1 || exit $?
        printf "pkgver=%s\npkgrel=%s\n" "${epoch:+$epoch:}${pkgver-}" "${pkgrel-}"
    ' _ "$pkg_path" 2>/dev/null
end

# Print an *expanded* PKGBUILD array, one element per line. Sourcing is the only
# way to get what makepkg sees: `source=(…tar.gz{,.sig})` is two entries and
# `{,-doc}` is two more, and a $pkgver inside an entry is a version. Tokenising
# the text instead gets both wrong — a mistake this audit made twice before
# catching it, and one that would silently miscalculate checksum coverage.
# (The checked form below is the caller-facing entry: it reports evaluation
# failure instead of masking it as an empty array.)

function pkgbuild_base -a pkg_path
    set -l pkgbase (pkgbuild_var "$pkg_path" pkgbase)
    if test -z "$pkgbase"
        set -l names (pkgbuild_array_checked "$pkg_path" pkgname)
        set -l names_status $status
        if test $names_status -eq 0; and test (count $names) -eq 1
            set pkgbase "$names[1]"
        end
    end
    if test -z "$pkgbase"
        set pkgbase (basename "$pkg_path")
    end
    echo "$pkgbase"
end

# Raw text of the first top-level `pkgver=` assignment, unevaluated. Empty when
# the recipe has no such line (a pkgver() function, which the sync paths skip).
function pkgbuild_pkgver_rhs -a pkg_path
    bash -c '
        while IFS= read -r line; do
            case "$line" in
                pkgver=*)
                    printf "%s\n" "${line#pkgver=}"
                    exit 0
                    ;;
            esac
        done <"$1/PKGBUILD"
        exit 1
    ' _ "$pkg_path" 2>/dev/null
end

# pkgbuild_pkgver_plan PKG_PATH TARGET
# Plan the bump of a COMPUTED pkgver (pkgver=${_major}.${_rcver}): print one
# `var=newvalue` row per variable assignment that must move for the expression
# to evaluate to TARGET. Every other referenced variable keeps its current
# value — the expression itself is never rewritten. The target is matched
# against the expression's literal/variable segmentation and the assignment is
# chosen by (1) keeping the most variables unchanged, then (2) the smallest
# total edit distance to their current values: a plain rc bump moves only
# _rcver, while a channel change lands on the split closest to what is there.
# Exit: 0 planned (zero rows = already at TARGET) · 2 the expression is not a
# literal-and-${var} construction (command substitution, exotic parameter
# expansion, or it references pkgver/pkgrel/epoch) · 3 a referenced variable
# has no single plain-literal assignment line to rewrite · 4 TARGET cannot be
# expressed through the expression at all.
function pkgbuild_pkgver_plan -a pkg_path target
    bash -c '
pkg_path=$1
target=$2
rhs=""
while IFS= read -r line; do
    case "$line" in
        pkgver=*) rhs=${line#pkgver=}; break ;;
    esac
done <"$pkg_path/PKGBUILD"
[[ -n $rhs ]] || exit 2
case "$rhs" in
    \"*\") rhs=${rhs#\"}; rhs=${rhs%\"} ;;
esac

# Tokenize into literal and variable segments. Anything beyond $var/${var}
# (command substitution, other parameter expansions) is refused, never guessed.
segs=()
seg_vars=()
lit=""
i=0
len=${#rhs}
while ((i < len)); do
    ch=${rhs:i:1}
    if [[ $ch == "$" ]]; then
        j=$((i + 1))
        if ((j < len)) && [[ ${rhs:j:1} == "{" ]]; then
            j=$((j + 1))
            name=""
            while ((j < len)) && [[ ${rhs:j:1} == [A-Za-z0-9_] ]]; do
                name+=${rhs:j:1}
                j=$((j + 1))
            done
            if [[ -z $name || ${rhs:j:1} != "}" ]]; then exit 2; fi
            end=$((j + 1))
        else
            name=""
            while ((j < len)) && [[ ${rhs:j:1} == [A-Za-z0-9_] ]]; do
                name+=${rhs:j:1}
                j=$((j + 1))
            done
            [[ -n $name ]] || exit 2
            end=$j
        fi
        [[ $name == [A-Za-z_]* ]] || exit 2
        case "$name" in pkgver | pkgrel | epoch) exit 2 ;; esac
        if [[ -n $lit ]]; then segs+=("L$lit"); lit=""; fi
        segs+=("V$name")
        seg_vars+=("$name")
        i=$end
    elif [[ $ch == "\`" ]]; then
        exit 2
    else
        lit+=$ch
        i=$((i + 1))
    fi
done
[[ -n $lit ]] && segs+=("L$lit")
has_var=0
for s in "${segs[@]}"; do [[ $s == V* ]] && has_var=1; done
((has_var)) || exit 2

cd "$pkg_path" || exit 2
source ./PKGBUILD >/dev/null 2>&1 || exit 2
declare -A cur=()
var_order=()
for name in "${seg_vars[@]}"; do
    [[ -z ${cur[$name]+x} ]] || continue
    var_order+=("$name")
    eval "cur[\$name]=\${$name-}"
    # Bumping means rewriting the assignment line, so it must exist exactly
    # once and hold a plain literal — a computed assignment is not ours to edit.
    [[ $(grep -c "^$name=" PKGBUILD) == 1 ]] || exit 3
    assign=$(grep -m1 "^$name=" PKGBUILD)
    val=${assign#*=}
    case "$val" in
        \"*\") val=${val#\"}; val=${val%\"} ;;
    esac
    [[ $val =~ ^[A-Za-z0-9._+-]*$ ]] || exit 3
done

# Enumerate every assignment of the expression that evaluates to TARGET.
# A variable runs up to the next literal (or the end), so candidates are
# bounded by that literal"s occurrences — never a combinatorial blow-up.
sep=$(printf "\037")
declare -a sols=()
solve() {
    local idx=$1 pos=$2 prefix=$3
    local tlen=${#target}
    if ((idx == ${#segs[@]})); then
        ((pos == tlen)) && sols+=("$prefix")
        return 0
    fi
    local seg=${segs[idx]}
    if [[ $seg == L* ]]; then
        local text=${seg#L}
        [[ ${target:pos:${#text}} == "$text" ]] || return 0
        solve $((idx + 1)) $((pos + ${#text})) "$prefix"
        return 0
    fi
    local nextlit=""
    if ((idx + 1 < ${#segs[@]})) && [[ ${segs[idx+1]} == L* ]]; then
        nextlit=${segs[idx+1]#L}
    fi
    if [[ -z $nextlit ]]; then
        if ((idx + 1 == ${#segs[@]})); then
            ((pos < tlen)) || return 0
            solve $((idx + 1)) $tlen "$prefix$sep${target:pos}"
        else
            local k
            for ((k = pos + 1; k <= tlen; k++)); do
                solve $((idx + 1)) $k "$prefix$sep${target:pos:k-pos}"
            done
        fi
        return 0
    fi
    local nl=${#nextlit} o
    for ((o = 1; pos + o + nl <= tlen; o++)); do
        [[ ${target:pos+o:nl} == "$nextlit" ]] || continue
        solve $((idx + 1)) $((pos + o)) "$prefix$sep${target:pos:o}"
    done
}
solve 0 0 ""
((${#sols[@]})) || exit 4

lev() {
    local a=$1 b=$2 i j
    local -a prev currow
    for ((j = 0; j <= ${#b}; j++)); do prev[j]=$j; done
    for ((i = 1; i <= ${#a}; i++)); do
        currow[0]=$i
        for ((j = 1; j <= ${#b}; j++)); do
            local cost=1
            [[ ${a:i-1:1} == "${b:j-1:1}" ]] && cost=0
            local m=$((prev[j] + 1))
            ((currow[j-1] + 1 < m)) && m=$((currow[j-1] + 1))
            ((prev[j-1] + cost < m)) && m=$((prev[j-1] + cost))
            currow[j]=$m
        done
        prev=("${currow[@]}")
    done
    printf "%s\n" "${prev[${#b}]}"
}

declare -A best=()
have_best=0
best_unchanged=-1
best_dist=1000000
for sol in "${sols[@]}"; do
    body=${sol#"$sep"}
    IFS=$sep read -r -a vals <<<"$body"
    ((${#vals[@]} == ${#seg_vars[@]})) || continue
    declare -A newval=()
    ok=1
    for ((k = 0; k < ${#seg_vars[@]}; k++)); do
        name=${seg_vars[k]}
        v=${vals[k]}
        if [[ -n ${newval[$name]+x} && ${newval[$name]} != "$v" ]]; then ok=0; break; fi
        newval[$name]=$v
    done
    ((ok)) || continue
    unchanged=0
    dist=0
    for name in "${var_order[@]}"; do
        if [[ ${cur[$name]} == "${newval[$name]}" ]]; then
            unchanged=$((unchanged + 1))
        else
            d=$(lev "${cur[$name]}" "${newval[$name]}")
            dist=$((dist + d))
        fi
    done
    if ((unchanged > best_unchanged)) || { ((unchanged == best_unchanged)) && ((dist < best_dist)); }; then
        have_best=1
        best_unchanged=$unchanged
        best_dist=$dist
        best=()
        for name in "${var_order[@]}"; do best[$name]=${newval[$name]}; done
    fi
done
((have_best)) || exit 4

for name in "${var_order[@]}"; do
    [[ ${cur[$name]} == "${best[$name]}" ]] && continue
    printf "%s=%s\n" "$name" "${best[$name]}"
done
exit 0
' _ "$pkg_path" "$target"
end

# version_sync_value_ok FIELD VALUE — the one charset gate every pkgver/pkgrel/
# epoch value must pass before it reaches sed program text or a PKGBUILD line.
# Those values arrive from OUTSIDE the tree (pacman -Si Version text, AUR and
# nvchecker metadata) and `&`, `\` and `/` corrupt a sed replacement rather than
# fail it — the nvchecker path gated this charset long before the Arch path did
# (2026-10-05); one gate, both paths, no second spelling of the rule.
function version_sync_value_ok -a field value
    switch $field
        case pkgver pkgrel
            string match -qr '^[A-Za-z0-9._+]+$' -- "$value"
        case epoch
            string match -qr '^[0-9]+$' -- "$value"
        case '*'
            return 1
    end
end

# pkgbuild_array_checked PKG_PATH NAME — pkgbuild_array's expansion with the
# recipe EVALUATION reported instead of masked (the inline `bash -c "source
# '…'"` snippets this replaces swallowed it into "no sources", so -ccc reported
# a clean scan over recipes it never read): rc 0 means the recipe evaluated
# (zero rows = a genuinely empty array), rc 2 means it could not be sourced.
# Positional arguments only — a recipe path may carry a quote the interpolated
# form would break or inject through (2026-10-05).
function pkgbuild_array_checked -a pkg_path name
    bash -c '
        [[ $2 =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || exit 2
        __gsa_arr_name=$2
        cd "$1" || exit 2
        source ./PKGBUILD >/dev/null 2>&1 || exit 2
        declare -p "$__gsa_arr_name" >/dev/null 2>&1 || exit 0
        eval "set -- \"\${$__gsa_arr_name[@]}\""
        (( $# )) || exit 0
        printf "%s\n" "$@"
    ' _ "$pkg_path" "$name" 2>/dev/null
end

# restore_pkgbuild_snapshot PKG_PATH SNAPSHOT — the checked restore every
# failure path uses. The restore is itself a tmp+mv publish (with a per-process
# temp name), so a reader never sees a half-copied recipe, and its failure is a
# RETURN STATUS, never a claim: callers fold it into theirs instead of printing
# "the recipe was restored" unconditionally — a recipe left rewritten after a
# failed restore is exactly what the owner must be told about (2026-10-05).
function restore_pkgbuild_snapshot -a pkg_path snapshot
    set -l work "$pkg_path/PKGBUILD.tmp.$fish_pid"
    if not cp -p -- "$snapshot" "$work"
        return 1
    end
    if not mv -f -- "$work" "$pkg_path/PKGBUILD"
        command rm -f -- "$work"
        return 1
    end
    return 0
end

# discard_staged_rewrite WORK STAGED_HERE — drop our own staged copy on an
# abort; a caller-supplied staged copy belongs to the caller's transaction and
# stays for the caller to discard.
function discard_staged_rewrite -a work staged
    if test "$staged" = "1"
        command rm -f -- "$work"
    end
end

# resolve_physical_dir PATH — the physical path of an existing directory.
# Resolution must NOT go through `cd`: fish 4.9.3 runs command substitutions
# IN-PROCESS, so the historical `(cd "$x" 2>/dev/null && pwd -P)` idiom silently
# relocated the builder's own cwd into $x (2026-10-06: the deleted version-sync
# temp dir then broke build_package's closing popd). Emits the path on stdout
# and fails without output when PATH is not an existing directory.
function resolve_physical_dir -a path
    if test -z "$path"; or not test -d "$path"
        return 1
    end
    realpath -- "$path" 2>/dev/null
end

# version_sync_temp_dir LABEL — the checked temporary-state gate: a verified
# scratch directory outside the repository, or a named reason in
# $_VERSION_SYNC_TMP_ERROR with rc 2. Deriving paths from an UNCHECKED mktemp
# collapses them to the filesystem root on failure ("/map", "/PKGBUILD.orig"),
# where a root-mode failure path would "restore" from /PKGBUILD.orig
# (2026-10-05). Every path below the call derives only from the verified
# directory it returns.
function version_sync_temp_dir -a label
    set -g _VERSION_SYNC_TMP_ERROR ""
    set -l repository_root (resolve_physical_dir "$SCRIPT_DIR")
    set -l tmp_base /tmp
    if set -q TMPDIR; and test -n "$TMPDIR"
        set tmp_base "$TMPDIR"
    end
    set tmp_base (resolve_physical_dir "$tmp_base")
    if test -z "$repository_root"; or test -z "$tmp_base"
        set -g _VERSION_SYNC_TMP_ERROR "cannot resolve a safe temporary directory"
        return 2
    end
    if test "$tmp_base" = "$repository_root"; or string match -q "$repository_root/*" -- "$tmp_base"
        set -g _VERSION_SYNC_TMP_ERROR "TMPDIR must be outside the repository"
        return 2
    end
    set -l tmp (mktemp -d "$tmp_base/gsa-$label.XXXXXXXX" 2>/dev/null)
    if test $status -ne 0; or test -z "$tmp"
        set -g _VERSION_SYNC_TMP_ERROR "cannot create an isolated temporary directory"
        return 2
    end
    set -l resolved (resolve_physical_dir "$tmp")
    if test -z "$resolved"
        command rm -rf -- "$tmp"
        set -g _VERSION_SYNC_TMP_ERROR "cannot resolve the isolated temporary directory"
        return 2
    end
    echo "$resolved"
end

# apply_pkgver_version PKG_PATH NEW_PKGVER [WORK_FILE] — rewrite a recipe's
# version.
# A literal `pkgver=` line is rewritten: the historical behaviour, unchanged.
# A COMPUTED `pkgver=${var}...` expression is never clobbered with a literal
# (that silently pins the version and defeats the variable tracking, the
# pkgver()-override hazard in reverse); instead the variables the expression
# expands are bumped so it evaluates to NEW_PKGVER. Handles any pkgver=${var}
# recipe, not one package's shape.
# Every write lands on WORK_FILE — the caller's staged copy — and the caller
# publishes the whole pkgver+pkgrel+epoch rewrite as ONE tmp+mv afterwards; a
# caller that passes none gets a staged copy of its own which is published
# atomically here. The tracked PKGBUILD is never edited in place (2026-10-05).
# Return: 0 applied (or nothing to do) · 2 the write failed (the caller owns
# restore semantics) · 3 unsupported pkgver expression · 4 NEW_PKGVER cannot be
# expressed through it · 5 a referenced variable cannot be rewritten.
function apply_pkgver_version -a pkg_path new_pkgver
    set -l pkg_name (basename "$pkg_path")
    set -l work "$argv[3]"
    set -l staged_here 0
    if test -z "$work"
        set work "$pkg_path/PKGBUILD.tmp.$fish_pid"
        if not cp -p -- "$pkg_path/PKGBUILD" "$work"
            ui_error "$pkg_name: could not stage the pkgver rewrite"
            return 2
        end
        set staged_here 1
    end
    if not version_sync_value_ok pkgver "$new_pkgver"
        if test $staged_here -eq 1
            command rm -f -- "$work"
        end
        ui_error "$pkg_name: refusing unsupported pkgver format '$new_pkgver'"
        return 4
    end
    set -l rhs (pkgbuild_pkgver_rhs "$pkg_path")

    # Computed iff bash would expand it: anything outside a single-quoted RHS
    # that carries $ or a command substitution. Everything else is a literal
    # line and keeps the historical rewrite byte for byte.
    set -l computed 0
    if not string match -q "'*'" -- "$rhs"
        if string match -q '*$*' -- "$rhs"; or string match -q '*`*' -- "$rhs"
            set computed 1
        end
    end

    if test $computed -eq 0
        if not sed -i "s/^pkgver=.*/pkgver=$new_pkgver/" "$work"
            if test $staged_here -eq 1
                command rm -f -- "$work"
            end
            return 2
        end
        if test $staged_here -eq 1
            if not mv -f -- "$work" "$pkg_path/PKGBUILD"
                command rm -f -- "$work"
                return 2
            end
        end
        return 0
    end

    # Computed: touch nothing unless the version must actually move.
    set -l cur_pkgver (pkgbuild_var "$pkg_path" pkgver)
    if test "$cur_pkgver" = "$new_pkgver"
        if test $staged_here -eq 1
            command rm -f -- "$work"
        end
        return 0
    end

    set -l plan (pkgbuild_pkgver_plan "$pkg_path" "$new_pkgver")
    set -l plan_status $status
    switch $plan_status
        case 0
            ;
        case 2
            ui_error "$pkg_name: pkgver is computed by an expression this version sync cannot rewrite (only literal-and-\${var} constructions are); bump its variables by hand"
            discard_staged_rewrite "$work" $staged_here
            return 3
        case 3
            ui_error "$pkg_name: a pkgver variable has no single plain-literal assignment line to rewrite; bump it by hand"
            discard_staged_rewrite "$work" $staged_here
            return 5
        case 4
            ui_error "$pkg_name: upstream version $new_pkgver cannot be expressed through this recipe's pkgver expression; the recipe keeps its current version"
            discard_staged_rewrite "$work" $staged_here
            return 4
        case '*'
            ui_error "$pkg_name: could not evaluate the recipe's pkgver expression"
            discard_staged_rewrite "$work" $staged_here
            return 3
    end

    for row in $plan
        set -l pair (string split -m 1 = -- "$row")
        if test (count $pair) -ne 2; or not string match -qr '^[A-Za-z_][A-Za-z0-9_]*$' -- "$pair[1]"
            ui_error "$pkg_name: version sync produced an invalid variable rewrite"
            discard_staged_rewrite "$work" $staged_here
            return 3
        end
        if not version_sync_value_ok pkgver "$pair[2]"
            ui_error "$pkg_name: version sync produced an unsupported value for $pair[1]"
            discard_staged_rewrite "$work" $staged_here
            return 3
        end
        if not sed -i "s/^$pair[1]=.*/$pair[1]=$pair[2]/" "$work"
            ui_error "$pkg_name: could not update $pair[1] for the computed pkgver"
            discard_staged_rewrite "$work" $staged_here
            return 2
        end
    end
    if test $staged_here -eq 1
        if not mv -f -- "$work" "$pkg_path/PKGBUILD"
            command rm -f -- "$work"
            return 2
        end
    end
    return 0
end

# apply_release_metadata WORK_FILE PKGREL EPOCH — the pkgrel/epoch half of a
# version rewrite, applied to the caller's STAGED PKGBUILD and never to the
# tracked file: the caller publishes the whole pkgver+pkgrel+epoch rewrite as
# one tmp+mv afterwards, so a reader never observes the recipe between two of
# its own fields (2026-10-05).
# Return: 0 applied · 2 the write failed · 4 an unvalidated value (callers gate
# first; this refuses anyway so no future caller routes around the gate).
function apply_release_metadata -a work pkgrel epoch
    if not version_sync_value_ok pkgrel "$pkgrel"; or not version_sync_value_ok epoch "$epoch"
        return 4
    end
    if not sed -i "s/^pkgrel=.*/pkgrel=$pkgrel/" "$work"
        return 2
    end
    if grep -q '^epoch=' "$work"
        if not sed -i "s/^epoch=.*/epoch=$epoch/" "$work"
            return 2
        end
    else if test "$epoch" -ne 0
        if not sed -i "/^pkgrel=.*/a epoch=$epoch" "$work"
            return 2
        end
    end
    return 0
end

# ─── Sync stable package version with Arch repos ─────────────────────────────
# Return contract (build_package switches on it):
#   0 = nothing to do — not a stable recipe, already current, the name is not
#       in the repos at all, or the repo version/pkgrel is a downgrade
#   1 = rewritten, and pkgver moved
#   2 = the rewrite was refused (unwritable version text) or failed; the
#       recipe is rolled back to its committed state
#   3 = rewritten, but only pkgrel/epoch moved
#   4 = the repo QUERY failed (a real failure — unsynced db, mirror error —
#       never the name-unknown answer, which is a 0): the committed version's
#       freshness is unverified and the caller must say so instead of silently
#       skipping or silently building it (2026-10-05)
#
# 1 and 3 are informational only: whether the committed sums went stale depends
# on whether a source=() entry actually changed, which build_package determines
# by diffing the expanded array around this call. See the comment there.
function sync_stable_version -a pkg_path
    # Only applies to recipes physically staged under packages/stable.
    string match -q "$SCRIPT_DIR/packages/stable/*" "$pkg_path"; or return 0

    # pkgver()-driven PKGBUILDs (Qt dev-branch builds) have NO stable pkgver=
    # line — inserting one would OVERRIDE pkgver() and pin the version to the
    # repo release, defeating dev tracking. Skip them; their describe-based
    # version is always ahead of the repo anyway (never-downgrade guard).
    if not grep -q '^pkgver=' "$pkg_path/PKGBUILD"
        return 0
    end

    set -l pkgbase (pkgbuild_var "$pkg_path" pkgbase)
    if test -z "$pkgbase"
        set pkgbase (basename "$pkg_path")
    end

    # Candidate names to query: pkgbase first, then every split package name
    # (resolved in bash so comments/variables in pkgname=() don't break it).
    # E.g. hip-runtime's PKGBUILD builds pkgname=(hip-runtime-amd) — the repo
    # only knows the latter, so a pkgbase-only query would silently NEVER sync
    # and -Syu would replace the custom build with the newer stock one.
    set -l candidates "$pkgbase"
    set -l pkgnames (pkgbuild_array_checked "$pkg_path" pkgname)
    if test $status -ne 0
        ui_error "$pkgbase: cannot evaluate the pkgname array of $pkg_path/PKGBUILD — the recipe is named here instead of being version-synced blind"
        return 2
    end
    for n in $pkgnames
        set -a candidates "$n"
    end

    # Query the latest version from the Arch repos. "The name is unknown"
    # (pacman's not-found answer) and "the QUERY failed" (unsynced db, broken
    # mirror) are different claims: the first leaves nothing to sync to, the
    # second leaves the committed version's freshness UNVERIFIED and must not
    # fold into the first — that silent fold is what let a stale version build
    # with no log and no note (2026-10-05).
    set -l repo_info ""
    set -l query_failure ""
    for c in $candidates
        set -l query_out (env LC_ALL=C pacman -Si "$c" 2>&1)
        set -l query_status $status
        set -l query_text (string join \n -- $query_out)
        if test $query_status -eq 0
            if test -n "$query_text"
                set repo_info $query_out
                break
            end
            # A zero-exit answer that advertises nothing: nothing to sync to.
            continue
        end
        if string match -qr "error: package '[^']*' was not found" -- "$query_text"
            continue
        end
        set query_failure "$query_text"
        break
    end
    if test -n "$query_failure"
        ui_error "$pkgbase: cannot query the Arch repository version — the committed version's freshness is unverified:"
        printf '  %s\n' "$query_failure"
        return 4
    end
    if test (count $repo_info) -eq 0
        return 0
    end

    set -l repo_ver_full (printf '%s\n' $repo_info | grep -m1 '^Version' | awk '{print $NF}')
    if test -z "$repo_ver_full"
        return 0
    end

    # Split "2.42.2-1", "7.2.4-1.1", or "1:7.1-1" (epoch) into epoch/version/release
    set -l repo_epoch 0
    set -l repo_v $repo_ver_full
    if string match -qr '^[0-9]+:' "$repo_v"
        set repo_epoch (string replace -r -- ':.*$' '' "$repo_v")
        set repo_v (string replace -r -- '^[0-9]+:' '' "$repo_v")
    end
    set -l repo_pkgver (string replace -r -- '-[0-9].*$' '' "$repo_v")
    set -l repo_pkgrel (string match -r -- '-([0-9].*)$' "$repo_v")[2]
    if test -z "$repo_pkgrel"
        set repo_pkgrel 1
    end

    # The parsed pieces are about to become sed program text and PKGBUILD
    # lines; `&`, `\` and `/` corrupt rather than fail, so the repository's own
    # answer is refused before the first write unless it is writeable verbatim.
    if not version_sync_value_ok pkgver "$repo_pkgver"; or not version_sync_value_ok pkgrel "$repo_pkgrel"; or not version_sync_value_ok epoch "$repo_epoch"
        ui_error "$pkgbase: refusing to sync from a repository version this rewrite cannot write safely: '$repo_ver_full'"
        return 2
    end

    # Read current version
    set -l cur_pkgver (pkgbuild_var "$pkg_path" pkgver)
    set -l cur_pkgrel (pkgbuild_var "$pkg_path" pkgrel)

    # Never downgrade the content version — repos can game vercmp with an epoch
    # (e.g. repo "1:7.1-1" vs local "7.2-1": 7.2 content is newer, keep it)
    set -l vercmp_res -1
    if type -q vercmp
        set vercmp_res (vercmp "$cur_pkgver" "$repo_pkgver")
    else if test "$cur_pkgver" = "$repo_pkgver"
        set vercmp_res 0
    end
    if test "$vercmp_res" -gt 0
        return 0
    end
    if test "$vercmp_res" -eq 0
        if test "$cur_pkgrel" = "$repo_pkgrel"
            return 0
        end
        # pkgver is at repo parity, so only a repo pkgrel that is actually
        # AHEAD is a sync worth making. A local pkgrel ahead of the repo is a
        # deliberate bump (e.g. ripgrep's Rust PGO wave carries pkgrel 2 over
        # the repo's 1), not staleness — rewriting it back to the repo value
        # clobbered ripgrep 15.2.0-2 to 15.2.0-1 on 2026-09-28, silently
        # re-stamping a PGO build with the pre-PGO revision identity. Same as
        # the pkgver guard above, the ordering rests on vercmp; without it the
        # inequality case falls through to the historical rewrite behaviour.
        set -l pkgrel_cmp 0
        if type -q vercmp
            set pkgrel_cmp (vercmp "$cur_pkgrel" "$repo_pkgrel")
        end
        if test "$pkgrel_cmp" -ge 0
            return 0
        end
    end

    if test "$_BUILD_QUIET" != "1"
        ui_info "$pkgbase: $cur_pkgver-$cur_pkgrel → $repo_pkgver-$repo_pkgrel (synced with repo)"
    end

    # Whether the *sources* move. A repo bump that carries only pkgrel or epoch
    # leaves source=() alone, so the committed sums still verify and the caller
    # must not treat the recipe as stale. Compared before the rewrite, because
    # the rewrite is what destroys the old value.
    set -l pkgver_changed 0
    if test "$cur_pkgver" != "$repo_pkgver"
        set pkgver_changed 1
    end
    set -l sources_before (pkgbuild_array_checked "$pkg_path" source)
    if test $status -eq 2
        ui_error "$pkgbase: cannot evaluate the PKGBUILD source array"
        return 2
    end

    # Snapshot before the FIRST write: every failure below — including one the
    # tree itself causes — rolls the recipe back instead of leaving a
    # half-rewritten PKGBUILD for the owner to commit (2026-10-05).
    set -l tmp (version_sync_temp_dir version-sync)
    if test $status -ne 0
        ui_error "$pkgbase: $_VERSION_SYNC_TMP_ERROR; the version sync cannot be made rollback-safe"
        return 2
    end
    set -l original "$tmp/PKGBUILD.original"
    if not cp -p -- "$pkg_path/PKGBUILD" "$original"
        ui_error "$pkgbase: cannot snapshot PKGBUILD before the version sync"
        remove_version_sync_temp "$tmp"
        return 2
    end

    # Update pkgver/pkgrel (+ epoch when the repo carries one — never inside pkgver,
    # makepkg rejects colons there). A computed pkgver=${var} recipe gets its
    # version variables bumped instead of the expression being overwritten with
    # a literal (apply_pkgver_version); a literal pkgver= line is rewritten
    # exactly as before. Every write lands on one staged copy and the whole
    # pkgver+pkgrel+epoch rewrite publishes with ONE tmp+mv, so no reader and
    # no second run can observe the recipe between two of its own fields, and
    # the per-process temp name cannot collide with a concurrent run's
    # (2026-10-05).
    set -l work "$pkg_path/PKGBUILD.tmp.$fish_pid"
    if not cp -p -- "$pkg_path/PKGBUILD" "$work"
        ui_error "$pkgbase: could not stage the version rewrite"
        remove_version_sync_temp "$tmp"
        return 2
    end
    apply_pkgver_version "$pkg_path" "$repo_pkgver" "$work"
    if test $status -ne 0
        command rm -f -- "$work"
        remove_version_sync_temp "$tmp"
        return 2
    end
    apply_release_metadata "$work" "$repo_pkgrel" "$repo_epoch"
    if test $status -ne 0
        command rm -f -- "$work"
        remove_version_sync_temp "$tmp"
        return 2
    end
    if not mv -f -- "$work" "$pkg_path/PKGBUILD"
        command rm -f -- "$work"
        remove_version_sync_temp "$tmp"
        return 2
    end

    # Clean stale source/build artifacts
    if not command rm -rf -- "$pkg_path/src" "$pkg_path/pkg" "$pkg_path/build"
        if not restore_version_sync_recipe "$pkg_path" "$original" "$tmp"
            return 2
        end
        ui_error "$pkgbase: could not clear stale build artifacts after the version sync; the recipe was rolled back to its committed version"
        return 2
    end

    # Run-level witness: a run never commits (the disposition of these edits is
    # the owner's), so the end-of-run summary must name every recipe this run
    # rewrote — best-effort append; the per-package log keeps the record
    # either way. The committed .SRCINFO is stale truth the moment pkgver
    # moves, and with no moved source the checksum anchor never runs to
    # refresh it — so refresh it here, and fold a failed refresh into the
    # witness instead of letting the summary claim a clean sync (2026-10-05).
    set -l sources_after (pkgbuild_array_checked "$pkg_path" source)
    if test $status -eq 2
        if not restore_version_sync_recipe "$pkg_path" "$original" "$tmp"
            return 2
        end
        ui_error "$pkgbase: cannot evaluate the rewritten PKGBUILD source array; the recipe was rolled back to its committed version"
        remove_version_sync_temp "$tmp"
        return 2
    end
    set -l source_count (count $sources_after)
    if test (count $sources_before) -gt $source_count
        set source_count (count $sources_before)
    end
    set -l moved_sources 0
    for i in (seq $source_count)
        if test "$sources_before[$i]" != "$sources_after[$i]"
            set moved_sources (math $moved_sources + 1)
        end
    end
    set -l srcinfo_refresh_status 0
    if test $moved_sources -eq 0
        refresh_package_srcinfo "$pkg_path" "the repository version was synced"
        set srcinfo_refresh_status $status
    end
    set -l synced_line "$pkgbase: $cur_pkgver-$cur_pkgrel → $repo_pkgver-$repo_pkgrel (synced with repo)"
    if test $srcinfo_refresh_status -ne 0
        set synced_line "$synced_line — the committed .SRCINFO could NOT be refreshed; regenerate it with 'makepkg --printsrcinfo' before committing"
    end
    printf '%s\n' "$synced_line" >>"$_STATE_DIR/synced.list" 2>/dev/null
    remove_version_sync_temp "$tmp"

    if test $pkgver_changed -eq 1
        return 1
    end
    return 3
end

function remove_version_sync_temp -a tmp
    if test -n "$tmp"; and test -d "$tmp"
        command rm -rf -- "$tmp"
    end
end

function restore_version_sync_recipe -a pkg_path original tmp
    set -l restore_status 0
    if not restore_pkgbuild_snapshot "$pkg_path" "$original"
        ui_error "$(basename "$pkg_path"): could not restore $pkg_path/PKGBUILD after version sync — it is left rewritten and must not be committed"
        set restore_status 1
    end
    remove_version_sync_temp "$tmp"
    return $restore_status
end

function sync_nvchecker_version -a package_id pkg_path
    set -l pkg_name "$package_id"
    set -l pkgbase (pkgbuild_base "$pkg_path")
    set -l config "$pkg_path/.nvchecker.toml"
    set -l resolver "$SCRIPT_DIR/tools/nvcheck.sh"
    if not test -f "$config"; or not test -f "$resolver"
        ui_error "$pkg_name: the opted-in nvchecker config or resolver is missing"
        return $lane_outcome_defer
    end

    set -l tmp (version_sync_temp_dir version-sync)
    if test $status -ne 0
        ui_error "$pkg_name: $_VERSION_SYNC_TMP_ERROR; version sync cannot be made rollback-safe"
        return $lane_outcome_defer
    end
    set -l original "$tmp/PKGBUILD.original"
    if not cp -p -- "$pkg_path/PKGBUILD" "$original"
        ui_error "$pkg_name: cannot snapshot PKGBUILD before version sync"
        remove_version_sync_temp "$tmp"
        return 2
    end

    set -l sync_key "$pkgbase"
    set -l provider_info (bash "$resolver" --provider "$config" "$sync_key" 2>"$tmp/provider.err")
    set -l provider_status $status
    if test $provider_status -ne 0; and test "$package_id" != "$pkgbase"
        # A tracker section may be named for the recipe's topology id instead
        # of its pkgbase: pkgbase is flavor-derived for some recipes
        # (linux-cachyos evaluates to linux-cachyos-rt-bore-lto from its
        # scheduler knobs) while the recipe identity is stable. pkgbase is
        # tried first, so a conventional section resolves exactly as before.
        set provider_info (bash "$resolver" --provider "$config" "$package_id" 2>"$tmp/provider.err")
        set provider_status $status
        if test $provider_status -eq 0
            set sync_key "$package_id"
        end
    end
    if test $provider_status -ne 0; or test (count $provider_info) -ne 2
        ui_error "$pkg_name: cannot read its nvchecker provider metadata"
        if test -s "$tmp/provider.err"
            sed 's/^/  /' "$tmp/provider.err"
        end
        remove_version_sync_temp "$tmp"
        return $lane_outcome_defer
    end
    set -l provider "$provider_info[1]"
    set -l provider_id "$provider_info[2]"

    set -l new_pkgver (env TMPDIR="$tmp" bash "$resolver" --resolve "$config" "$sync_key" 2>"$tmp/resolve.err")
    set -l resolve_status $status
    if test $resolve_status -ne 0; or test (count $new_pkgver) -ne 1
        ui_error "$pkg_name: nvchecker could not resolve a version from $provider_id"
        if test -s "$tmp/resolve.err"
            sed 's/^/  /' "$tmp/resolve.err"
        end
        remove_version_sync_temp "$tmp"
        return $lane_outcome_defer
    end
    if not version_sync_value_ok pkgver "$new_pkgver"
        ui_error "$pkg_name: refusing unsupported upstream pkgver format '$new_pkgver'"
        remove_version_sync_temp "$tmp"
        return 4
    end

    set -l aur_srcinfo ""
    set -l aur_pkgrel ""
    set -l aur_epoch 0
    if test "$provider" = aur
        if not type -q curl
            ui_error "$pkg_name: cannot read AUR metadata because curl is missing"
            remove_version_sync_temp "$tmp"
            return $lane_outcome_defer
        end
        set aur_srcinfo "$tmp/aur.SRCINFO"
        if not curl -fsSL --max-time 60 --connect-timeout 10 -o "$aur_srcinfo" \
            "https://aur.archlinux.org/cgit/aur.git/plain/.SRCINFO?h=$provider_id" \
            2>"$tmp/aur-curl.err"
            ui_error "$pkg_name: AUR .SRCINFO for $provider_id is unavailable"
            if test -s "$tmp/aur-curl.err"
                sed 's/^/  /' "$tmp/aur-curl.err"
            end
            remove_version_sync_temp "$tmp"
            return $lane_outcome_defer
        end
        set -l aur_pkgbase (srcinfo_pkgbase "$aur_srcinfo")
        set -l aur_pkgver (srcinfo_pkgver "$aur_srcinfo")
        if test "$aur_pkgbase" != "$provider_id"; or test "$aur_pkgbase" != "$pkgbase"; or test "$aur_pkgver" != "$new_pkgver"
            ui_error "$pkg_name: AUR .SRCINFO changed or disagrees with nvchecker (expected $provider_id $new_pkgver, got $aur_pkgbase $aur_pkgver)"
            remove_version_sync_temp "$tmp"
            return $lane_outcome_defer
        end
        set aur_pkgrel (srcinfo_pkgrel "$aur_srcinfo")
        set -l aur_pkgrel_status $status
        set aur_epoch (srcinfo_epoch "$aur_srcinfo")
        if test $aur_pkgrel_status -ne 0; or not version_sync_value_ok pkgrel "$aur_pkgrel"; or not version_sync_value_ok epoch "$aur_epoch"
            ui_error "$pkg_name: AUR .SRCINFO has an invalid pkgrel or epoch"
            remove_version_sync_temp "$tmp"
            return $lane_outcome_defer
        end
    end

    set -l cur_pkgver (pkgbuild_var "$pkg_path" pkgver)
    set -l cur_pkgrel (pkgbuild_var "$pkg_path" pkgrel)
    set -l cur_epoch (pkgbuild_var "$pkg_path" epoch)
    if test -z "$cur_pkgrel"
        set cur_pkgrel 1
    end
    if test -z "$cur_epoch"
        set cur_epoch 0
    end
    if test -z "$cur_pkgver"; or not version_sync_value_ok pkgver "$cur_pkgver"; or not version_sync_value_ok pkgrel "$cur_pkgrel"; or not version_sync_value_ok epoch "$cur_epoch"
        ui_error "$pkg_name: the current PKGBUILD version metadata is invalid"
        remove_version_sync_temp "$tmp"
        return 4
    end
    if not type -q vercmp
        ui_error "$pkg_name: cannot compare versions because vercmp is missing"
        remove_version_sync_temp "$tmp"
        return $lane_outcome_defer
    end
    set -l version_order (vercmp "$cur_pkgver" "$new_pkgver")
    if test $status -ne 0
        ui_error "$pkg_name: vercmp could not compare $cur_pkgver and $new_pkgver"
        remove_version_sync_temp "$tmp"
        return $lane_outcome_defer
    end
    if test $version_order -gt 0
        remove_version_sync_temp "$tmp"
        return 0
    end

    set -l new_pkgrel "$cur_pkgrel"
    set -l new_epoch "$cur_epoch"
    if test "$provider" = aur
        if test $version_order -lt 0
            set new_pkgrel "$aur_pkgrel"
            set new_epoch "$aur_epoch"
        else
            set -l release_order (vercmp "$cur_pkgrel" "$aur_pkgrel")
            if test $release_order -lt 0
                set new_pkgrel "$aur_pkgrel"
            end
            if test "$aur_epoch" -gt "$cur_epoch"
                set new_epoch "$aur_epoch"
            end
        end
    else if test "$provider" = github; and test $version_order -lt 0
        set new_pkgrel 1
    end

    if not test -f "$pkg_path/PKGBUILD"; or not grep -q '^pkgver=' "$pkg_path/PKGBUILD"; or not grep -q '^pkgrel=' "$pkg_path/PKGBUILD"
        ui_error "$pkg_name: PKGBUILD must define literal pkgver and pkgrel fields for version sync"
        remove_version_sync_temp "$tmp"
        return 4
    end
    set -l pkgver_changed 0
    if test "$cur_pkgver" != "$new_pkgver"
        set pkgver_changed 1
    end
    set -l metadata_changed 0
    if test "$pkgver_changed" -eq 1; or test "$cur_pkgrel" != "$new_pkgrel"; or test "$cur_epoch" != "$new_epoch"
        set metadata_changed 1
    end
    set -l sources_before (pkgbuild_array_checked "$pkg_path" source)
    if test $status -ne 0
        ui_error "$pkg_name: cannot evaluate the current PKGBUILD source array"
        remove_version_sync_temp "$tmp"
        return 4
    end

    if test "$metadata_changed" -eq 1
        # A literal pkgver= line is rewritten; a computed pkgver=${var}...
        # expression has its variables bumped instead (e.g. _rcver=rc3 →
        # _rcver=rc5), never clobbered with a literal. One staged copy, one
        # publish: pkgver+pkgrel+epoch land together, so no reader and no
        # second run can observe the recipe between two of its own fields, and
        # the per-process temp name cannot collide with a concurrent run's
        # (2026-10-05).
        set -l work "$pkg_path/PKGBUILD.tmp.$fish_pid"
        if not cp -p -- "$pkg_path/PKGBUILD" "$work"
            ui_error "$pkg_name: could not stage the version rewrite"
            restore_version_sync_recipe "$pkg_path" "$original" "$tmp"
            return 2
        end
        apply_pkgver_version "$pkg_path" "$new_pkgver" "$work"
        set -l pkgver_write_status $status
        if test $pkgver_write_status -eq 2
            ui_error "$pkg_name: could not update pkgver"
            command rm -f -- "$work"
            restore_version_sync_recipe "$pkg_path" "$original" "$tmp"
            return 2
        else if test $pkgver_write_status -ne 0
            # The computed-pkgver planner refused (unsupported expression, an
            # unrewritable variable, or the version is not expressible through
            # the recipe's pkgver expression) and already said why.
            command rm -f -- "$work"
            restore_version_sync_recipe "$pkg_path" "$original" "$tmp"
            return 4
        end
        apply_release_metadata "$work" "$new_pkgrel" "$new_epoch"
        set -l release_write_status $status
        if test $release_write_status -ne 0
            if test $release_write_status -eq 2
                ui_error "$pkg_name: could not update pkgrel/epoch"
            end
            command rm -f -- "$work"
            restore_version_sync_recipe "$pkg_path" "$original" "$tmp"
            return 2
        end
        if not mv -f -- "$work" "$pkg_path/PKGBUILD"
            ui_error "$pkg_name: could not publish the version rewrite"
            command rm -f -- "$work"
            restore_version_sync_recipe "$pkg_path" "$original" "$tmp"
            return 2
        end
        if not command rm -rf -- "$pkg_path/src" "$pkg_path/pkg" "$pkg_path/build"
            ui_error "$pkg_name: could not clear artifacts after version sync"
            restore_version_sync_recipe "$pkg_path" "$original" "$tmp"
            return 2
        end
    end

    set -l sources_after (pkgbuild_array_checked "$pkg_path" source)
    if test $status -ne 0
        ui_error "$pkg_name: resolved pkgver cannot be evaluated by its PKGBUILD; the recipe was restored"
        restore_version_sync_recipe "$pkg_path" "$original" "$tmp"
        return 4
    end
    if test "$provider" = aur; and not srcinfo_matches_sources "$aur_srcinfo" "$pkg_path"
        ui_error "$pkg_name: AUR .SRCINFO sources do not cover every source of the rewritten recipe; the recipe was restored"
        restore_version_sync_recipe "$pkg_path" "$original" "$tmp"
        return $lane_outcome_defer
    end

    set -l moved_sources
    set -l source_count (count $sources_after)
    if test (count $sources_before) -gt $source_count
        set source_count (count $sources_before)
    end
    set -l source_index 1
    while test $source_index -le $source_count
        set -l before ""
        set -l after ""
        if test $source_index -le (count $sources_before)
            set before "$sources_before[$source_index]"
        end
        if test $source_index -le (count $sources_after)
            set after "$sources_after[$source_index]"
        end
        if test "$before" != "$after"; and test -n "$after"
            set -a moved_sources "$after"
        end
        set source_index (math $source_index + 1)
    end

    set -l srcinfo_refresh_status 0
    if test (count $moved_sources) -gt 0
        anchor_sums_from_provider "$pkg_path" "$provider" "$provider_id" "$aur_srcinfo" $moved_sources
        set -l anchor_status $status
        switch $anchor_status
            case 0
                # The checksum pipeline also refreshes a committed .SRCINFO.
                set srcinfo_refresh_status 0
            case 1
                refresh_package_srcinfo "$pkg_path" "version metadata was synced"
                set srcinfo_refresh_status $status
            case 4
                restore_version_sync_recipe "$pkg_path" "$original" "$tmp"
                return 4
            case 5
                # The checksum-anchor failure could not roll its own rewrite
                # back; its message already named the dirty recipe.
                restore_version_sync_recipe "$pkg_path" "$original" "$tmp"
                return 2
            case 2 3
                restore_version_sync_recipe "$pkg_path" "$original" "$tmp"
                return $lane_outcome_defer
            case '*'
                ui_error "$pkg_name: unexpected checksum-anchor result $anchor_status"
                restore_version_sync_recipe "$pkg_path" "$original" "$tmp"
                return 2
        end
    else if test "$metadata_changed" -eq 1
        refresh_package_srcinfo "$pkg_path" "version metadata was synced"
        set srcinfo_refresh_status $status
    end

    if test "$metadata_changed" -eq 0
        remove_version_sync_temp "$tmp"
        return 0
    end
    set -l provider_label "$provider_id"
    if test "$provider" = aur
        set provider_label "AUR $provider_id"
    else
        set provider_label "GitHub $provider_id"
    end
    set -l old_version "$cur_pkgver-$cur_pkgrel"
    set -l new_version "$new_pkgver-$new_pkgrel"
    if test "$cur_epoch" -ne 0
        set old_version "$cur_epoch:$old_version"
    end
    if test "$new_epoch" -ne 0
        set new_version "$new_epoch:$new_version"
    end
    if test "$_BUILD_QUIET" != "1"
        ui_info "$pkgbase: $old_version → $new_version (synced with $provider_label)"
    end
    set -l synced_line "$pkgbase: $old_version → $new_version (synced with $provider_label)"
    if test $srcinfo_refresh_status -ne 0
        # The run summary must carry the gap the per-package warning alone
        # would bury: the committed .SRCINFO is now stale truth for later gates
        # until the owner regenerates it (2026-10-05).
        set synced_line "$synced_line — the committed .SRCINFO could NOT be refreshed; regenerate it with 'makepkg --printsrcinfo' before committing"
    end
    printf '%s\n' "$synced_line" >>"$_STATE_DIR/synced.list" 2>/dev/null
    remove_version_sync_temp "$tmp"
    if test "$pkgver_changed" -eq 1
        return 1
    end
    return 3
end

# The URL part of a source entry, with any "name::" override removed, or nothing
# when the entry is an in-tree file (a patch, a dotfile, an .install script) that
# has no URL and so nothing to download.
function source_url -a entry
    set -l e $entry
    if string match -q '*::*' -- $e
        set e (string replace -r '^.*::' '' -- $e)
    end
    string match -q '*://*' -- $e; or return 1
    echo $e
end

# The VCS protocol of a source entry (git/svn/hg/bzr), or nothing for a plain
# download. It must be read from the URL part, after the "name::" prefix is
# removed: "fish::git+https://…" is a git checkout, and testing the raw entry
# misses it, so the checkout is then treated as a tarball and the build refused.
function source_vcs -a entry
    set -l e (source_url $entry); or return 1
    for p in git svn hg bzr
        if string match -q "$p+*" -- $e
            echo $p
            return 0
        end
    end
    return 1
end

# The name makepkg gives one source entry, which is what a checksum array
# describes: the "name::" override when the entry has one, otherwise the
# basename of the URL. Nothing is printed for a signature file (makepkg writes
# SKIP for those) or for an in-tree file, because neither is a download that a
# checksum published elsewhere can describe. The suffix list must cover every
# spelling of a detached signature — '.sign' is the kernel.org one
# (linux-7.2.7.tar.sign), and missing it is what made an official-SKIP entry
# look unanchorable and refused the recipe (measured 2026-09-24: makepkg
# verifies .sign with PGP against validpgpkeys — corrupting it fails the build
# with 'SIGNATURE NOT FOUND' — so its integrity is cryptographic, not a hash).
#
# The override matters: 'udisks2::git+…' downloads to "udisks2", and
# 'openshadinglanguage-…tar.gz::https://…/v1.15.3.0.tar.gz' downloads to
# "openshadinglanguage-…tar.gz", not to the URL's basename. Reading the basename
# instead made the verifier look for a file that does not exist, and — worse, for
# util-linux's renamed LICENSE — find a *different* file that happened to share
# it, which is a false mismatch in that case and a false *pass* in the other
# direction.
function source_filename -a entry
    set -l name ""
    if string match -q '*::*' -- $entry
        set name (string replace -r '::.*$' '' -- $entry)
    else
        set -l url (source_url $entry); or return 1
        set name (string replace -r '[?#].*$' '' -- $url)
        set name (string replace -r '^.*/' '' -- $name)
    end
    if test -z "$name"
        return 1
    end
    for suffix in .sig .asc .signature .sign
        string match -q "*$suffix" -- $name; and return 1
    end
    echo $name
end

# The protocol, URL, and selected ref from an expanded VCS source entry.
# Return one item per line so values containing spaces remain intact.
function vcs_source_ref_info -a entry
    set -l protocol (source_vcs "$entry"); or return 1
    set -l raw (source_url "$entry"); or return 1
    set raw (string replace -r '^(git|svn|hg|bzr)\+' '' -- "$raw")
    set -l parts (string split -m 1 '#' -- "$raw")
    set -l url "$parts[1]"
    set -l fragment ""
    if test (count $parts) -gt 1
        set fragment "$parts[2]"
    end
    set url (string replace -r '\?signed$' '' -- "$url")
    set fragment (string replace -r '\?signed$' '' -- "$fragment")

    set -l ref_kind default
    set -l ref_value -
    if test -n "$fragment"
        if string match -q '*=*' -- "$fragment"
            set ref_kind (string replace -r '=.*$' '' -- "$fragment")
            set ref_value (string replace -r '^[^=]*=' '' -- "$fragment")
        else
            set ref_kind revision
            set ref_value "$fragment"
        end
    end
    printf '%s\n' "$protocol" "$url" "$ref_kind" "$ref_value"
end

# Hash the expanded entry so revision records never expose credential-bearing URLs.
function vcs_source_key -a entry
    set -l key (printf '%s' "$entry" | sha256sum 2>/dev/null | cut -d ' ' -f1)
    string match -qr '^[0-9a-f]{64}$' -- "$key"; or return 1
    echo "$key"
end

# Locate the checkout makepkg actually compiled from. The authoritative root
# is $srcdir ($startdir/src/<name>): download_git keeps only the mirror in
# SRCDEST, extract_git clones the working copy into $srcdir, and
# build()/package() cd into it — so the src/ probe needs no environment at
# all, which matters because sudo's env_reset strips SRCDEST from the
# recorder's own environment in root-supervisor runs (2026-10-02 xdg-utils:
# 'missing local checkout' after a green build, the checkout one directory
# deeper in src/ the whole time). A mirror — in SRCDEST, or at the package
# root when SRCDEST defaults to $startdir — is a download cache whose HEAD is
# the remote's default branch, not the built ref (measured: mirror HEAD
# 03707c1f while the archive was compiled from 356c380a), so the package-root
# and SRCDEST roots are fallbacks only, tried when src/ has no working copy.
# Git strips .git from its default source name; honor both spellings in
# every root.
function vcs_source_checkout -a pkg_path entry
    set -l name (source_filename "$entry"); or return 1
    set -l names "$name"
    set -l stripped (string replace -r '\.git$' '' -- "$name")
    if test "$stripped" != "$name"
        set -a names "$stripped"
    end
    set -l roots "$pkg_path/src" "$pkg_path"
    if set -q SRCDEST; and test -n "$SRCDEST"
        set -a roots "$SRCDEST"
    end
    for root in $roots
        for candidate_name in $names
            set -l candidate "$root/$candidate_name"
            if test -d "$candidate"
                echo "$candidate"
                return 0
            end
        end
    end
    return 1
end

function vcs_local_revision -a protocol checkout
    switch "$protocol"
        case git
            env GIT_CONFIG_COUNT=0 git -c safe.bareRepository=all -C "$checkout" rev-parse --verify HEAD 2>/dev/null
        case svn
            command svn info --show-item revision "$checkout" 2>/dev/null
        case hg
            command hg --cwd "$checkout" log -r . --template '{node}' 2>/dev/null
        case bzr
            command bzr version-info --custom '--template={revision_id}' "$checkout" 2>/dev/null
        case '*'
            return 1
    end
end

# git_ls_remote [git-ls-remote args...] — one Git upstream query with a
# transport classifier and bounded retry. The exit status separates a
# COMPLETED query (0 = match, 2 = clean "no such ref" under --exit-code —
# never retried, an answer does not change on repetition) from a transport
# failure (anything else: TLS, timeout, dead host — no answer at all, the
# only retryable class; measured 2026-10-02: repo.or.cz answered 1 of 3
# attempts within a minute, so one shot is not an oracle for "upstream is
# gone"). 6 attempts, 2/5/10/20/40 s backoff (~93 s budget): the 2026-10-07
# run #47/#48 deferrals showed repo.or.cz TLS-eof failures arrive in BURSTS
# that outlast the old 4-attempt/17 s budget (idle probes 2026-10-07 answered
# again within ~60 s of an all-fail burst), so a short budget converts
# transport noise into an upstream-unverified deferral. Exhaustion returns
# the failing status with no rows; callers keep treating "no rows" as
# unresolvable.
# A persistent condition that LOOKS like transport (expired credentials,
# proxy 403) is retried and then fails the same way — the classifier only
# gates retries, never trust, so a misclassification costs latency, never a
# skip decision. Args are passed through verbatim so option order
# (--symref before the URL) stays the caller's.
function git_ls_remote_quiet
    set -l attempt 1
    while true
        set -l rows (env GIT_CONFIG_COUNT=0 GIT_TERMINAL_PROMPT=0 git \
            -c safe.bareRepository=all ls-remote $argv 2>/dev/null)
        set -l query_status $status
        if test $query_status -eq 0; or test $query_status -eq 2; or test $attempt -ge 6
            printf '%s\n' $rows
            return $query_status
        end
        # Flaky upstreams (repo.or.cz drops ~half of TLS handshakes from some
        # networks) need a window in seconds, not milliseconds (2026-10-02) —
        # and one that outlasts a failure BURST, hence the growing backoff.
        switch $attempt
            case 1
                sleep 2
            case 2
                sleep 5
            case 3
                sleep 10
            case 4
                sleep 20
            case 5
                sleep 40
        end
        set attempt (math $attempt + 1)
    end
end

# Resolve the selected upstream ref, not an unrelated repository HEAD. Fixed
# Git commits and numeric SVN revisions are immutable inputs.
function vcs_remote_revision -a protocol url ref_kind ref_value
    switch "$protocol"
        case git
            switch "$ref_kind"
                case commit
                    string match -qr '^[0-9a-fA-F]{7,64}$' -- "$ref_value"; or return 1
                    echo (string lower -- "$ref_value")
                    return 0
                case branch
                    set -l target "$ref_value"
                    if not string match -q 'refs/heads/*' -- "$target"
                        set target "refs/heads/$target"
                    end
                    set -l rows (git_ls_remote_quiet --exit-code "$url" "$target")
                    for row in $rows
                        set -l fields (string split \t -- "$row")
                        if test (count $fields) -eq 2; and test "$fields[2]" = "$target"
                            string match -qr '^[0-9a-fA-F]{40,64}$' -- "$fields[1]"; or return 1
                            echo (string lower -- "$fields[1]")
                            return 0
                        end
                    end
                    return 1
                case tag
                    set -l target "$ref_value"
                    if not string match -q 'refs/tags/*' -- "$target"
                        set target "refs/tags/$target"
                    end
                    set -l peeled "$target^{}"
                    set -l rows (git_ls_remote_quiet --exit-code "$url" "$target" "$peeled")
                    set -l tag_revision ""
                    set -l peeled_revision ""
                    for row in $rows
                        set -l fields (string split \t -- "$row")
                        if test (count $fields) -eq 2
                            if test "$fields[2]" = "$target"
                                set tag_revision "$fields[1]"
                            else if test "$fields[2]" = "$peeled"
                                set peeled_revision "$fields[1]"
                            end
                        end
                    end
                    set -l revision "$peeled_revision"
                    if test -z "$revision"
                        set revision "$tag_revision"
                    end
                    string match -qr '^[0-9a-fA-F]{40,64}$' -- "$revision"; or return 1
                    echo (string lower -- "$revision")
                    return 0
                case default
                    set -l rows (git_ls_remote_quiet --symref --exit-code "$url" HEAD)
                    for row in $rows
                        set -l fields (string split \t -- "$row")
                        if test (count $fields) -eq 2; and test "$fields[2]" = HEAD
                            if string match -qr '^[0-9a-fA-F]{40,64}$' -- "$fields[1]"
                                echo (string lower -- "$fields[1]")
                                return 0
                            end
                        end
                    end
                    return 1
                case '*'
                    return 1
            end
        case svn
            if test "$ref_kind" != default; and test "$ref_kind" != revision
                return 1
            end
            if test "$ref_kind" = default
                set ref_value HEAD
            end
            if test "$ref_value" != HEAD; and string match -qr '^[0-9]+$' -- "$ref_value"
                echo "$ref_value"
                return 0
            end
            set -l revision (command svn --non-interactive info --show-item revision \
                --revision "$ref_value" "$url" 2>/dev/null)
            string match -qr '^[0-9]+$' -- "$revision"; or return 1
            echo "$revision"
            return 0
        case hg
            if test "$ref_kind" != default; and test "$ref_kind" != branch \
                and test "$ref_kind" != revision; and test "$ref_kind" != tag
                return 1
            end
            if test "$ref_kind" = default
                set ref_value default
            end
            set -l revision (command hg --config ui.interactive=False identify \
                --template '{node}' --rev "$ref_value" "$url" 2>/dev/null)
            string match -qr '^[0-9a-fA-F]{40,64}$' -- "$revision"; or return 1
            echo (string lower -- "$revision")
            return 0
        case bzr
            if test "$ref_kind" != default; and test "$ref_kind" != revision
                return 1
            end
            set -l args version-info --custom '--template={revision_id}'
            if test "$ref_kind" = revision
                set -a args "--revision=$ref_value"
            end
            set -a args "$url"
            set -l revision (command bzr $args 2>/dev/null)
            test -n "$revision"; or return 1
            echo "$revision"
            return 0
        case '*'
            return 1
    end
end

# Store one revision record for every distinct VCS source used by an archive.
# The sidecar is ignored by the existing *.pkg.tar.* rule and replaced atomically.
function record_vcs_archive_revisions -a pkg_path archive
    set -g _VCS_REVISION_ERROR ""
    set -l manifest "$archive.gsa-vcs-revisions"
    set -l entries
    set -l keys
    set -l src_entries (pkgbuild_array_checked "$pkg_path" source)
    if test $status -eq 2
        set -g _VCS_REVISION_ERROR "cannot evaluate the PKGBUILD source array"
        return 1
    end
    for entry in $src_entries
        set -l protocol (source_vcs "$entry")
        or continue
        set -l key (vcs_source_key "$entry")
        if test -z "$key"
            set -g _VCS_REVISION_ERROR "cannot identify a VCS source entry"
            return 1
        end
        if contains -- "$key" $keys
            continue
        end
        set -a keys "$key"
        set -a entries "$entry"
    end

    if test (count $entries) -eq 0
        if test -e "$manifest"; and not command rm -f -- "$manifest"
            set -g _VCS_REVISION_ERROR "cannot remove stale VCS revision metadata"
            return 1
        end
        return 0
    end

    # The manifest is bound to THIS archive build (2026-10-05): a SIGKILL
    # during a later rebuild skips this function's caller entirely, and the
    # old record must never bless whatever that kill left behind at the final
    # archive name. The size rejects any truncated write outright; the
    # checksum is the identity for same-size replacements. A fingerprint that
    # cannot be taken refuses the bless — a build whose record cannot be bound
    # is never skippable.
    set -l archive_size (stat -c %s -- "$archive" 2>/dev/null)
    set -l archive_sha ""
    if test -n "$archive_size"
        set archive_sha (string split -m1 ' ' -- (sha256sum -- "$archive" 2>/dev/null))[1]
    end
    if test -z "$archive_size"; or not string match -qr '^[0-9a-f]{64}$' -- "$archive_sha"
        set -g _VCS_REVISION_ERROR "cannot fingerprint the built archive"
        return 1
    end

    # The archive changed; invalidate any old record before collecting its new
    # revisions so a failed capture cannot make the replacement look current.
    if test -e "$manifest"; and not command rm -f -- "$manifest"
        set -g _VCS_REVISION_ERROR "cannot replace VCS revision metadata"
        return 1
    end
    set -l temporary (mktemp "$manifest.tmp.XXXXXX" 2>/dev/null)
    if test -z "$temporary"
        set -g _VCS_REVISION_ERROR "cannot create VCS revision metadata"
        return 1
    end
    if not printf 'gsa-vcs-revisions\t2\narchive\t%s\t%s\n' "$archive_sha" "$archive_size" >"$temporary"
        command rm -f -- "$temporary"
        set -g _VCS_REVISION_ERROR "cannot write VCS revision metadata"
        return 1
    end

    for entry in $entries
        set -l info (vcs_source_ref_info "$entry")
        if test (count $info) -ne 4
            command rm -f -- "$temporary"
            set -g _VCS_REVISION_ERROR "cannot parse a VCS source ref"
            return 1
        end
        set -l checkout (vcs_source_checkout "$pkg_path" "$entry")
        if test -z "$checkout"
            command rm -f -- "$temporary"
            set -l name (source_filename "$entry")
            set -g _VCS_REVISION_ERROR "missing local checkout for $name"
            return 1
        end
        set -l revision (vcs_local_revision "$info[1]" "$checkout")
        if test -z "$revision"
            command rm -f -- "$temporary"
            set -l name (source_filename "$entry")
            set -g _VCS_REVISION_ERROR "cannot read the built revision for $name"
            return 1
        end
        set -l key (vcs_source_key "$entry")
        if test -z "$key"; or not printf '%s\t%s\t%s\n' "$key" "$info[1]" "$revision" >>"$temporary"
            command rm -f -- "$temporary"
            set -g _VCS_REVISION_ERROR "cannot write VCS revision metadata"
            return 1
        end
    end

    if not mv -f -- "$temporary" "$manifest"
        command rm -f -- "$temporary"
        set -g _VCS_REVISION_ERROR "cannot publish VCS revision metadata"
        return 1
    end
    if test "$_ROOT_MODE" = "1"; and not chown "$_BUILD_USER": "$manifest"
        set -g _VCS_REVISION_ERROR "cannot restore VCS revision metadata ownership"
        return 1
    end
    return 0
end

# Confirm every selected source ref can be resolved before rebuilding an
# archive whose saved baseline is missing or unusable.
function vcs_selected_refs_queryable
    for entry in $argv
        set -l info (vcs_source_ref_info "$entry")
        if test (count $info) -ne 4
            set -g _VCS_REVISION_ERROR "cannot parse a VCS source ref"
            return 1
        end
        set -l current (vcs_remote_revision "$info[1]" "$info[2]" "$info[3]" "$info[4]")
        if test -z "$current"
            set -l name (source_filename "$entry")
            set -g _VCS_REVISION_ERROR "cannot query upstream revision for $name"
            return 1
        end
    end
    return 0
end

# The freshness tolerance: how many upstream commits a recorded baseline may
# trail a moving Git ref before -s stops waiving the rebuild. GSA_VCS_SKIP_TOLERANCE
# overrides the default 5; the value must be a positive integer and anything
# else falls back to the default LOUDLY (a silently ignored knob would make
# skip decisions unexplainable). Resolved once per process into a global
# (command substitution would run in a subshell and lose the memo).
# Rationale (owner design 2026-10-03): we are CONSUMERS of llvm/rust/qt6, not
# their developers — rebuilding a 2-hour package because upstream landed two
# commits is pure waste.
function vcs_skip_tolerance_resolve
    if set -q _VCS_SKIP_TOLERANCE
        return 0
    end
    set -l tolerance 5
    if set -q GSA_VCS_SKIP_TOLERANCE
        if string match -qr '^[1-9][0-9]*$' -- "$GSA_VCS_SKIP_TOLERANCE"
            set tolerance "$GSA_VCS_SKIP_TOLERANCE"
        else
            ui_warning "GSA_VCS_SKIP_TOLERANCE='$GSA_VCS_SKIP_TOLERANCE' is not a positive integer — using the default $tolerance"
        end
    end
    set -g _VCS_SKIP_TOLERANCE "$tolerance"
    return 0
end

# The fetch refspec for a selected Git ref — one home for the ref-kind →
# refspec mapping shared by the advance probes (vcs_remote_revision keeps its
# own ls-remote argument shapes).
function vcs_git_fetch_refspec -a ref_kind ref_value
    switch "$ref_kind"
        case default
            echo HEAD
        case branch
            if string match -q 'refs/heads/*' -- "$ref_value"
                echo "$ref_value"
            else
                echo "refs/heads/$ref_value"
            end
        case tag
            if string match -q 'refs/tags/*' -- "$ref_value"
                echo "$ref_value"
            else
                echo "refs/tags/$ref_value"
            end
        case '*'
            return 1
    end
end

# vcs_git_advance_distance URL REFSPEC BASELINE TIP DEPTH → the commit
# distance from BASELINE to TIP on stdout (rc 0), or rc 1 when it cannot be
# measured (no output).
# Rationale (the shallow-window trick): callers only need bounded questions
# about the advance ("fewer than tolerance new commits?" / "what may we CLAIM
# about the count?"), so one bounded shallow fetch into a scratch bare repo
# answers without cloning the world. --depth=DEPTH fetches the tip and its
# DEPTH-1 nearest ancestors — exactly the distances 1..DEPTH-1 are measurable
# (measured 2026-10-03: with --depth=6 a baseline 5 back counts 5; 10 back is
# absent and `rev-list --count` fails with "Invalid revision range"). DEPTH is
# caller-chosen: the tolerance path wants tolerance+1 (the boundary AT the
# tolerance must count), the ABI-provider path wants a wider informational
# window (its verdict is already fixed; the count is for the loud line).
# --filter=tree:0 keeps the fetch commits-only where the server honours
# partial-clone filters (e.g. GitHub); servers that ignore it fetch the window's
# trees and still work. A failing `rev-list` MEANS the distance exceeds the
# window (or history was rewritten — the baseline is not a recent ancestor of
# the new tip, so it is not in the fetch window either) and the caller must
# treat it as ">= the window", never as a small move. A fetch that never
# succeeds (after the same bounded transport retries as git_ls_remote_quiet —
# the tip query already worked, so a fetch failure is likely another flake) is
# likewise unmeasurable: a waiver needs PROOF; nothing else may lower the
# verification.
function vcs_git_advance_distance -a url refspec baseline tip depth
    # mktemp -d honours $TMPDIR by itself (GNU coreutils).
    set -l scratch (mktemp -d 2>/dev/null)
    if test -z "$scratch"
        return 1
    end
    set -l repo "$scratch/repo.git"
    set -l fetched 0
    set -l attempt 1
    if env GIT_CONFIG_COUNT=0 GIT_TERMINAL_PROMPT=0 git init --bare -q "$repo" 2>/dev/null
        while test $attempt -le 3
            if env GIT_CONFIG_COUNT=0 GIT_TERMINAL_PROMPT=0 git -C "$repo" \
                fetch -q --depth="$depth" --filter=tree:0 --no-tags \
                "$url" "$refspec" 2>/dev/null
                set fetched 1
                break
            end
            switch $attempt
                case 1
                    sleep 2
                case 2
                    sleep 5
            end
            set attempt (math $attempt + 1)
        end
    end
    set -l distance ""
    if test $fetched -eq 1
        set distance (env GIT_CONFIG_COUNT=0 git -C "$repo" \
            rev-list --count "$baseline..$tip" 2>/dev/null)
    end
    command rm -rf -- "$scratch"
    if not string match -qr '^[1-9][0-9]*$' -- "$distance"
        return 1
    end
    echo "$distance"
    return 0
end

# The informational measurement window for ABI-provider freshness waivers: how
# much upstream movement a marked recipe's loud line can count exactly. 64
# absorbs days of llvm-project movement ("dozens of commits an hour") while
# staying a bounded, commits-only fetch where the server honours
# --filter=tree:0; past it the line names the window instead of inventing a
# count — the verdict (waived) is identical either way.
set -g _VCS_ABI_ADVANCE_WINDOW 64

# The marker that makes a recipe an ABI provider: an (empty or one-line
# rationale) `.gsa-abi-provider` file in the recipe directory. One home for
# the predicate so every future call site reads the marker the same way.
function vcs_abi_provider_marked -a pkg_path
    test -e "$pkg_path/.gsa-abi-provider"
end

# Return 0 when a VCS archive is current — including when a moved Git ref is
# within the freshness tolerance, or when the recipe is an ABI provider (see
# below), in which case _FRESHNESS_WAIVER names the waiver line(s) and
# _FRESHNESS_WAIVER_REASON the claim (freshness-waived / abi-provider-waived —
# a waived-freshness skip is not the same claim as an untouched one).
# Return 1 when a selected ref moved past the tolerance, 2 when its current
# state cannot be established, and 3 when a rebuild can establish a missing or
# unusable baseline. Both -s callers defer (rc 99) on 2 — an unverifiable
# upstream must neither fail the run nor license a skip. The tolerance and the
# ABI-provider waiver only soften the 0/1 boundary; 2 and 3 are untouched.
function vcs_archive_is_current -a pkg_path archive
    set -g _VCS_REVISION_ERROR ""
    set -g _FRESHNESS_WAIVER
    set -g _FRESHNESS_WAIVER_REASON ""
    set -l entries
    set -l keys
    set -l src_entries (pkgbuild_array_checked "$pkg_path" source)
    if test $status -eq 2
        set -g _VCS_REVISION_ERROR "cannot evaluate the PKGBUILD source array"
        return 2
    end
    for entry in $src_entries
        set -l protocol (source_vcs "$entry")
        or continue
        set -l key (vcs_source_key "$entry")
        if test -z "$key"
            set -g _VCS_REVISION_ERROR "cannot identify a VCS source entry"
            return 2
        end
        if contains -- "$key" $keys
            continue
        end
        set -a keys "$key"
        set -a entries "$entry"
    end
    if test (count $entries) -eq 0
        return 0
    end

    set -l manifest "$archive.gsa-vcs-revisions"
    if not test -f "$manifest"
        if not vcs_selected_refs_queryable $entries
            return 2
        end
        set -g _VCS_REVISION_ERROR "no recorded VCS baseline for "(basename "$archive")
        return 3
    end
    set -l manifest_count (awk -F '\t' '
        NR == 1 {
            if ($0 != "gsa-vcs-revisions\t2") bad = 1
            next
        }
        NR == 2 {
            if ($1 != "archive" || $2 !~ /^[0-9a-f]{64}$/ || $3 !~ /^[0-9]+$/) bad = 1
            next
        }
        NF != 3 || length($1) != 64 || $1 !~ /^[0-9a-f]+$/ ||
            $2 !~ /^(git|svn|hg|bzr)$/ || $3 == "" { bad = 1; next }
        { count++ }
        END {
            if (bad) exit 1
            printf "%d\n", count + 0
        }
    ' "$manifest" 2>/dev/null)
    set -l expected_count (count $entries)
    if test -z "$manifest_count"; or test "$manifest_count" != "$expected_count"
        if not vcs_selected_refs_queryable $entries
            return 2
        end
        set -g _VCS_REVISION_ERROR "VCS baseline is missing, malformed, or belongs to different sources"
        return 3
    end

    # The baseline is bound to the exact archive build it was recorded for
    # (record_vcs_archive_revisions). A SIGKILL during a later rebuild leaves
    # the OLD manifest beside whatever the kill left of the NEW archive, and
    # without this check that record would bless the replacement and -s would
    # skip it forever. Size rejects any truncated write; the checksum rejects
    # a same-size replacement. Mismatch is an unusable baseline: rebuild once
    # to re-record, never skip.
    set -l identity (awk -F '\t' 'NR == 2 { print $2; print $3 }' "$manifest" 2>/dev/null)
    set -l actual_size (stat -c %s -- "$archive" 2>/dev/null)
    set -l actual_sha ""
    if test -n "$actual_size"
        set actual_sha (string split -m1 ' ' -- (sha256sum -- "$archive" 2>/dev/null))[1]
    end
    if test (count $identity) -ne 2; or test -z "$actual_size"; \
        or test "$actual_size" != "$identity[2]"; or test "$actual_sha" != "$identity[1]"
        if not vcs_selected_refs_queryable $entries
            return 2
        end
        set -g _VCS_REVISION_ERROR "VCS baseline was recorded for a different build of "(basename "$archive")
        return 3
    end

    for entry in $entries
        set -l info (vcs_source_ref_info "$entry")
        set -l key (vcs_source_key "$entry")
        if test (count $info) -ne 4; or test -z "$key"
            set -g _VCS_REVISION_ERROR "cannot parse a VCS source ref"
            return 2
        end
        set -l fields (awk -F '\t' -v key="$key" \
            '$1 == key { print $2; print $3 }' "$manifest" 2>/dev/null)
        if test (count $fields) -ne 2; or test "$fields[1]" != "$info[1]"
            if not vcs_selected_refs_queryable $entries
                return 2
            end
            set -l name (source_filename "$entry")
            set -g _VCS_REVISION_ERROR "VCS baseline does not match source $name"
            return 3
        end
        set -l current (vcs_remote_revision "$info[1]" "$info[2]" "$info[3]" "$info[4]")
        if test -z "$current"
            set -l name (source_filename "$entry")
            set -g _VCS_REVISION_ERROR "cannot query upstream revision for $name"
            return 2
        end
        if test "$info[1]" = git; and test "$info[3]" = commit
            if not string match -q "$current*" -- "$fields[2]"
                set -l name (source_filename "$entry")
                set -g _VCS_REVISION_ERROR "pinned Git commit does not match source $name"
                return 1
            end
        else if test "$fields[2]" != "$current"
            set -l name (source_filename "$entry")
            # ABI-provider waiver (owner rule 2026-10-03: "not building the
            # already built abi provider which is extremely heavy"): a recipe
            # marked .gsa-abi-provider is the matched ABI provider of its
            # consumer chain — rebuilding it invalidates every dependent's ABI
            # (rust must rebuild after it: the owner's cascade rule) and costs
            # hours, while its upstream moves far faster than any tolerance can
            # absorb (llvm-project lands dozens of commits an hour). For such a
            # recipe mere upstream movement NEVER rebuilds: the verdict is
            # "freshness waived", not "tolerated" — any distance, any VCS kind
            # (svn/hg/bzr have no commit distance and waive the same way).
            # Purely the 0/1 boundary for marked recipes: an unusable/missing
            # baseline (rc 3) still rebuilds once to record it, an unverifiable
            # upstream (rc 2) still defers, a mismatched pinned commit is local
            # inconsistency (not movement) and still rebuilds — and only -s is
            # exempt: an explicit build rebuilds normally.
            if vcs_abi_provider_marked "$pkg_path"
                set -l abi_id (basename "$pkg_path")
                set -l moved_claim "upstream revision moved"
                if test "$info[1]" = git; and test "$info[3]" != commit
                    set -l refspec (vcs_git_fetch_refspec "$info[3]" "$info[4]")
                    set -l distance (vcs_git_advance_distance "$info[2]" "$refspec" \
                        "$fields[2]" "$current" "$_VCS_ABI_ADVANCE_WINDOW")
                    if string match -qr '^[1-9][0-9]*$' -- "$distance"
                        set moved_claim "upstream moved $distance commit(s)"
                    else
                        # Never invent a count the window could not measure
                        # (rewritten history reads unmeasurable too).
                        set moved_claim "upstream moved past the measurement window ($_VCS_ABI_ADVANCE_WINDOW commits)"
                    end
                end
                set -a _FRESHNESS_WAIVER "$moved_claim — $abi_id is an ABI provider; freshness waived (rebuild only on measured skew or an explicit build)"
                set -g _FRESHNESS_WAIVER_REASON abi-provider-waived
                continue
            end
            # Freshness tolerance (owner design 2026-10-03): a handful of new
            # upstream commits is noise for a CONSUMER of llvm/rust/qt6, so -s
            # waives the rebuild while the measured advance stays strictly
            # below the tolerance (vcs_skip_tolerance_resolve). Git only: the
            # measurement is a commit distance, which svn/hg/bzr revisions do
            # not have — those keep exact-match as the conservative default.
            # Pinned Git commits are immutable inputs and cannot advance at
            # all. The waiver never lowers verification silently: no measured
            # distance strictly below the tolerance (see
            # vcs_git_advance_distance's unmeasurable = >= tolerance contract)
            # means no skip.
            if test "$info[1]" = git; and test "$info[3]" != commit
                vcs_skip_tolerance_resolve
                set -l tolerance "$_VCS_SKIP_TOLERANCE"
                set -l refspec (vcs_git_fetch_refspec "$info[3]" "$info[4]")
                set -l distance (vcs_git_advance_distance "$info[2]" "$refspec" \
                    "$fields[2]" "$current" (math "$tolerance" + 1))
                if string match -qr '^[1-9][0-9]*$' -- "$distance"
                    and test "$distance" -lt "$tolerance"
                    set -a _FRESHNESS_WAIVER "upstream moved $distance commit(s) < tolerance $tolerance — treating $name as current"
                    set -g _FRESHNESS_WAIVER_REASON freshness-waived
                    continue
                end
            end
            set -g _VCS_REVISION_ERROR "selected upstream ref moved for source $name"
            return 1
        end
    end
    return 0
end

# Snapshot archive path, nanosecond mtime, and size so records are written only
# for files makepkg actually replaced (including split outputs).
function package_archive_snapshot -a pkg_path
    find "$pkg_path" -maxdepth 1 -type f -name '*.pkg.tar.zst' \
        -printf '%p\t%T@\t%s\n' 2>/dev/null
end

# The pkgver a .SRCINFO declares for its pkgbase, or nothing when it has none.
function srcinfo_pkgver -a srcinfo
    for line in (cat "$srcinfo" 2>/dev/null)
        if string match -qr '^\s*pkgname\s*=' -- $line
            break
        end
        if string match -qr '^\s*pkgver\s*=' -- $line
            echo (string replace -r '^\s*pkgver\s*=\s*' '' -- $line)
            return 0
        end
    end
    return 1
end

function srcinfo_base_value -a srcinfo field
    for line in (cat "$srcinfo" 2>/dev/null)
        if string match -qr '^\s*pkgname\s*=' -- "$line"
            break
        end
        if string match -qr -- "^\s*$field\s*=" "$line"
            echo (string replace -r -- "^\s*$field\s*=\s*" '' "$line")
            return 0
        end
    end
    return 1
end

function srcinfo_pkgbase -a srcinfo
    srcinfo_base_value "$srcinfo" pkgbase
end

function srcinfo_pkgrel -a srcinfo
    srcinfo_base_value "$srcinfo" pkgrel
end

function srcinfo_epoch -a srcinfo
    set -l epoch (srcinfo_base_value "$srcinfo" epoch)
    if test -z "$epoch"
        echo 0
    else
        echo $epoch
    end
end

function srcinfo_base_sources -a srcinfo
    for line in (cat "$srcinfo" 2>/dev/null)
        if string match -qr '^\s*pkgname\s*=' -- "$line"
            break
        end
        if string match -qr '^\s*source\s*=' -- "$line"
            echo (string replace -r '^\s*source\s*=\s*' '' -- "$line")
        end
    end
end

function srcinfo_matches_sources -a srcinfo pkg_path
    set -g _SRCINFO_EXTRA_SOURCES
    set -l published_sources (srcinfo_base_sources "$srcinfo")
    set -l recipe_sources (pkgbuild_array_checked "$pkg_path" source)
    if test $status -ne 0
        return 1
    end
    # A provider record carrying files the recipe does not is still a
    # different packaging when the recipe carries none at all (the pre-2026-10-07
    # count equality caught that).
    if test (count $recipe_sources) -eq 0; and test (count $published_sources) -gt 0
        return 1
    end
    # COVERAGE, not equality: every source the recipe ships must appear
    # verbatim in the published list, but a published SUPERSET is valid and
    # its extras are reported, never anchored (2026-10-07 gcc-snapshot: AUR
    # carries gcc-ada-repro.patch for the ada frontend this recipe trims, and
    # byte equality refused a checksum anchor that was correct for every
    # source the recipe does build).
    for s in $recipe_sources
        if not contains -- "$s" $published_sources
            return 1
        end
    end
    for p in $published_sources
        if not contains -- "$p" $recipe_sources
            set -a _SRCINFO_EXTRA_SOURCES "$p"
        end
    end
    if test (count $_SRCINFO_EXTRA_SOURCES) -gt 0
        echo "  note: the provider .SRCINFO carries "(count $_SRCINFO_EXTRA_SOURCES)" source(s) this recipe does not build: "(string join ', ' -- $_SRCINFO_EXTRA_SOURCES)
    end
    return 0
end

# Checksum map for one recipe as "<file>\t<algorithm>\t<value>", read from
# the *pkgbase* section of a .SRCINFO.
#
# makepkg writes .SRCINFO with every `source =` line in order, then each checksum
# array in order, and it is already brace-expanded — so it is both easier and
# safer to read than a provider PKGBUILD, which would have to be *executed* to
# be expanded. Sources and sums only line up *within* one algorithm, though:
# Arch and AUR publish the same file list once per algorithm (fish has one
# source with both a sha512 and a b2 sum), so the flat list is not aligned. Only
# the first contiguous run of one algorithm is used, and the function returns 1
# unless that run is exactly as long as the source list, so an unparseable file
# can never be anchored to.
function srcinfo_sum_map -a srcinfo
    set -l srcs
    set -l algos
    set -l vals
    for line in (cat "$srcinfo" 2>/dev/null)
        if string match -qr '^\s*pkgname\s*=' -- $line
            break
        end
        if string match -qr '^\s*source\s*=' -- $line
            set -a srcs (string replace -r '^\s*source\s*=\s*' '' -- $line)
        else if string match -qr '^\s*(sha256|sha512|b2|md5)sums\s*=' -- $line
            set -a algos (string replace -r 'sums$' '' -- (string replace -r '^\s*([a-z0-9]+)\s*=.*$' '$1' -- $line))
            set -a vals (string replace -r '^\s*[a-z0-9]+\s*=\s*' '' -- $line)
        end
    end
    if test (count $srcs) -eq 0; or test (count $algos) -lt (count $srcs)
        return 1
    end
    set -l alg $algos[1]
    set -l run 0
    for a in $algos
        if test "$a" != "$alg"
            break
        end
        set run (math $run + 1)
    end
    if test $run -ne (count $srcs)
        return 1
    end
    for i in (seq (count $srcs))
        if test -z "$vals[$i]"; or test "$vals[$i]" = "SKIP"
            continue
        end
        set -l f (source_filename $srcs[$i])
        if test -z "$f"
            continue
        end
        printf '%s\t%s\t%s\n' $f $alg $vals[$i]
    end
end

function github_release_checksum_map -a repo pkgver tmp map_file tag_file
    if not type -q python3
        ui_error "$repo: Python 3 is required to read GitHub release metadata"
        return 2
    end
    set -l found_release 0
    for tag in "$pkgver" "v$pkgver"
        set -l response "$tmp/github-release-$tag.json"
        set -l http_code (curl --silent --show-error --location \
            --max-time 60 --connect-timeout 10 --output "$response" \
            --write-out '%{http_code}' \
            "https://api.github.com/repos/$repo/releases/tags/$tag" \
            2>"$tmp/github-curl.err")
        set -l curl_status $status
        if test $curl_status -ne 0
            ui_error "$repo: GitHub release metadata request failed for tag $tag (curl exit $curl_status)"
            if test -s "$tmp/github-curl.err"
                tail -5 "$tmp/github-curl.err" | sed 's/^/  /'
            end
            return 2
        end
        if test "$http_code" = 404
            continue
        end
        if test "$http_code" != 200
            ui_error "$repo: GitHub release metadata for tag $tag returned HTTP $http_code"
            return 2
        end
        if not bash "$SCRIPT_DIR/tools/nvcheck.sh" --release-digests "$response" "$tag" \
            >"$map_file" 2>"$tmp/github-json.err"
        then
            ui_error "$repo: cannot read GitHub release metadata for tag $tag"
            if test -s "$tmp/github-json.err"
                sed 's/^/  /' "$tmp/github-json.err"
            end
            return 2
        end
        printf '%s\n' "$tag" >"$tag_file"
        set found_release 1
        break
    end
    if test $found_release -eq 0
        printf '' >"$map_file"
        printf '' >"$tag_file"
    end
    return 0
end

function github_source_matches_release -a entry repo tag
    if test -z "$tag"
        return 1
    end
    set -l url (source_url "$entry"); or return 1
    set url (string replace -r '[?#].*$' '' -- "$url")
    string match -q "https://github.com/$repo/releases/download/$tag/*" -- "$url"
end

function github_release_asset_name -a entry
    set -l url (source_url "$entry"); or return 1
    set url (string replace -r '[?#].*$' '' -- "$url")
    set -l name (string replace -r '^.*/' '' -- "$url")
    if test -z "$name"
        return 1
    end
    echo "$name"
end

# refresh_package_srcinfo PKG_PATH REASON — regenerate the committed .SRCINFO
# through makepkg and publish it atomically (one staged write with a
# per-process name; the shared .SRCINFO.tmp name let two runs on one recipe
# destroy each other's work, 2026-10-05).
# Return: 0 refreshed, or no committed .SRCINFO to refresh (nothing to do) ·
# 1 makepkg --printsrcinfo failed · 2 the refreshed file could not replace the
# committed one. A failure is surfaced twice on purpose: a named line carrying
# the regeneration command, and a run-summary witness (synced.list →
# print_synced_notes) — the stale committed .SRCINFO stays the truth later
# gates read until the owner regenerates it, and a warning only the package log
# holds is where that fact used to go to die.
function refresh_package_srcinfo -a pkg_path reason
    if not test -f "$pkg_path/.SRCINFO"
        return 0
    end
    set -l pkg_name (basename "$pkg_path")
    set -l tmp_srcinfo "$pkg_path/.SRCINFO.tmp.$fish_pid"
    set -l run_as env
    if test "$_ROOT_MODE" = "1"
        set run_as sudo -u "$_BUILD_USER" env HOME=$_BUILD_HOME
    end
    if not $run_as makepkg --printsrcinfo --dir "$pkg_path" >"$tmp_srcinfo" 2>/dev/null
        command rm -f -- "$tmp_srcinfo"
        ui_warning "$pkg_name: $reason but the committed .SRCINFO could not be refreshed; regenerate it with 'makepkg --printsrcinfo > .SRCINFO'"
        printf '%s: %s but the committed .SRCINFO could NOT be refreshed — regenerate it with makepkg --printsrcinfo before committing\n' \
            "$pkg_name" "$reason" >>"$_STATE_DIR/synced.list" 2>/dev/null
        return 1
    end
    if not mv -f -- "$tmp_srcinfo" "$pkg_path/.SRCINFO"
        command rm -f -- "$tmp_srcinfo"
        ui_warning "$pkg_name: $reason but the refreshed .SRCINFO could not replace the committed file"
        printf '%s: %s but the refreshed .SRCINFO could NOT replace the committed file\n' \
            "$pkg_name" "$reason" >>"$_STATE_DIR/synced.list" 2>/dev/null
        return 2
    end
    return 0
end

# makepkg's own checksum for one VCS source: it hashes `git archive --format tar
# <tag>` of the checkout, so the value is reproducible on any machine and the
# provider's published value is a cross-check rather than a local echo. Prints
# nothing and returns 1 when there is nothing to recompute yet (no checkout, or
# a fragment makepkg itself would answer SKIP for); returns 2 when the
# recomputation was attempted and failed.
function vcs_source_sum -a dir entry alg
    set -l url (source_url $entry); or return 1
    if not string match -q '*#*' -- $url
        return 1
    end
    set -l frag (string replace -r '^[^#]*#' '' -- $url)
    # makepkg appends verification flags to the fragment (#tag=v262?signed);
    # the ref name itself must never carry them or `git archive` looks up a
    # ref that cannot exist and the anchor reports a false checksum mismatch
    # (2026-10-02, systemd). Same rule as the shared source parser.
    set frag (string replace -r '\?signed$' '' -- $frag)
    set -l kind (string replace -r '=.*$' '' -- $frag)
    if test "$kind" != tag; and test "$kind" != commit
        return 1
    end
    set -l val (string replace -r '^[^=]*=' '' -- $frag)
    set -l name (source_filename $entry); or return 1
    # makepkg's get_filename strips a trailing .git from a VCS URL (the clone
    # of …/pipewire.git lands in 'pipewire'), while source_filename keeps the
    # URL spelling the provider map is keyed by — try both spellings, or the
    # checkout is "not available" no matter how healthy it is (2026-09-30).
    set -l name_stripped (string replace -r '\.git$' '' -- $name)
    set -l cands "$dir/$name"
    if test "$name_stripped" != "$name"
        set -a cands "$dir/$name_stripped"
    end
    if set -q SRCDEST; and test -n "$SRCDEST"
        set -a cands "$SRCDEST/$name"
        if test "$name_stripped" != "$name"
            set -a cands "$SRCDEST/$name_stripped"
        end
    end
    set -l repo ""
    for cand in $cands
        if test -d "$cand"
            set repo "$cand"
            break
        end
    end
    if test -z "$repo"
        return 1
    end
    set -l sum_file (mktemp); or return 2
    # The archive is written to a file, not piped: a failing git would
    # otherwise hash empty stdin and report a confident wrong sum. Any git
    # failure (incl. host git hardening on bare repos) is case 2, not a value.
    if not git -c core.abbrev=no -C "$repo" archive --format tar "$val" >"$sum_file" 2>/dev/null
        command rm -f -- "$sum_file"
        return 2
    end
    set -l sum (command "$alg"sum <"$sum_file" | string replace -r '\s+.*$' '')
    command rm -f -- "$sum_file"
    if test -z "$sum"
        return 2
    end
    echo $sum
end

# ─── Re-anchor moved sources to the selected version provider ────────────────
# A provider version can move a source=() URL away from the bytes described by
# the committed sums. Never treat updpkgsums alone as verification: use a
# provider-published checksum when available, and otherwise report the existing
# loud fetch-only policy.
#
# When a provider publishes no checksum for an entry, refresh it loudly as
# fetch-only instead of claiming the new hash is an anchor. The log and the run
# summary name every such entry and the remaining attestation (PGP for a
# detached signature — already outside this list via source_filename —,
# #tag/#commit for a VCS source, TLS for a plain download). Published values
# remain anchor-or-refuse: verify them after writing and restore on disagreement.
#
# The caller passes only moved entries. In the default Arch path, a pkgver
# rewrite that leaves source=() alone — 26 of the 28 stable recipes pin literal
# versions in their URLs — leaves the committed sums valid, so refusing those
# builds would be a false alarm, and so would re-hashing them.
#
# updpkgsums does the writing, so the recipe keeps its own formatting and its own
# choice of algorithm; the values are then verified against the selected
# provider's, whatever algorithm it publishes, and the check is per-file so a
# disagreement names the file. Every path fails closed, restoring the recipe
# where it was already rewritten.
#
# Return: 0 = anchored (and any refresh-only entries recorded) · 1 = nothing
#         to anchor · 2 = provider/fetch/write failure · 3 = no matching
#         provider metadata · 4 = a source disagrees with a published checksum.
#         5 = a failure whose restore ALSO failed: nothing was built, but the
#         recipe is left rewritten and must not be committed — the caller must
#         treat 5 as its own named outcome, never as the primary code's.
function anchor_sums_from_provider -a pkg_path provider provider_id provider_file
    set -l pkg_name (basename "$pkg_path")
    set -l pkgbase (pkgbuild_var "$pkg_path" pkgbase)
    if test -z "$pkgbase"
        if test "$provider" = aur
            set pkgbase (pkgbuild_base "$pkg_path")
        else
            set pkgbase $pkg_name
        end
    end
    set -l pkgver (pkgbuild_var "$pkg_path" pkgver)
    set -l pkgrel (pkgbuild_var "$pkg_path" pkgrel)
    set -l refuse_manual "  Refresh them by hand — 'updpkgsums' in that recipe, commit, rebuild. '--no-sync' builds the committed version as-is."
    set -l authority_phrase "the official"
    set -l checksum_owner "Arch"
    if test "$provider" = aur
        set authority_phrase "AUR"
        set checksum_owner "AUR"
        set refuse_manual "  No package was built; the recipe was restored. Retry when AUR metadata is available, or use '--no-sync' to build the committed version and sums. Do not treat a fetched hash as an upstream anchor."
    else if test "$provider" = github
        set authority_phrase "GitHub"
        set checksum_owner "GitHub"
        set refuse_manual "  No package was built; the recipe was restored. Retry when GitHub metadata is available, or use '--no-sync' to build the committed version and sums. Do not treat a fetched hash as an upstream anchor."
    end

    # Which of the moved sources a checksum published elsewhere can describe at
    # all: an in-tree file was not downloaded and a signature file gets SKIP.
    set -l anchor_names
    set -l anchor_entries
    for e in $argv[5..-1]
        if test -z (source_url $e)
            continue
        end
        set -l fn (source_filename $e)
        if test -z "$fn"
            continue
        end
        if contains -- $fn $anchor_names
            continue
        end
        set -a anchor_names $fn
        set -a anchor_entries $e
    end
    if test (count $anchor_names) -eq 0
        return 1
    end

    if not type -q curl
        if test "$provider" = arch
            ui_error "$pkg_name: refusing to build — pkgver was synced to $pkgver-$pkgrel and 'curl' is missing, so the official checksums cannot be read"
        else
            ui_error "$pkg_name: refusing to build — pkgver was synced to $pkgver-$pkgrel and 'curl' is missing, so provider checksum metadata cannot be read"
        end
        echo "$refuse_manual"
        return 2
    end
    if not type -q updpkgsums
        ui_error "$pkg_name: refusing to build — pkgver was synced to $pkgver-$pkgrel and 'updpkgsums' is missing, so the sums cannot be refreshed (it ships with pacman)"
        echo "$refuse_manual"
        return 2
    end

    # Checked gate: an unchecked mktemp here collapsed every derived path to
    # the filesystem root on failure ("/map", "/PKGBUILD.orig"), where the
    # root-mode failure path would "restore" from /PKGBUILD.orig (2026-10-05).
    set -l tmp (version_sync_temp_dir anchor-sums)
    if test $status -ne 0
        ui_error "$pkg_name: refusing to build — pkgver was synced to $pkgver-$pkgrel and $_VERSION_SYNC_TMP_ERROR, so no checksum state can be held safely"
        echo "$refuse_manual"
        return 2
    end

    set -l srcinfo ""
    set -l published "$provider_id"
    set -l map "$tmp/map"
    set -l release_tag ""
    switch "$provider"
        case arch
            # The pkgbase is usually right; some recipes follow a name Arch
            # does not (hip-runtime lives under hip), so try split names too.
            # `main` comes first; the version's own tag is the fallback when
            # the packaging repo has moved past the repo version.
            set -l tried
            set -l seen_pkg ""
            set -l seen_ver ""
            set -l out_names (pkgbuild_array_checked "$pkg_path" pkgname)
            if test $status -eq 2
                ui_error "$pkgbase: cannot evaluate the PKGBUILD pkgname array; no checksum state can be held safely"
                return 2
            end
            for c in $pkgbase $out_names
                if test -z "$c"
                    continue
                end
                if contains -- $c $tried
                    continue
                end
                set -a tried $c
                for r in main "$pkgver-$pkgrel"
                    set -l f "$tmp/$c-$r.SRCINFO"
                    if not curl -fsSL --max-time 60 -o "$f" "https://gitlab.archlinux.org/archlinux/packaging/packages/$c/-/raw/$r/.SRCINFO" 2>/dev/null
                        continue
                    end
                    if not test -s "$f"
                        continue
                    end
                    # A revision that does not carry our pkgver is no anchor:
                    # it describes different files.
                    set -l v (srcinfo_pkgver "$f")
                    if test -z "$v"
                        continue
                    end
                    if test "$v" = "$pkgver"
                        set srcinfo "$f"
                        set published "$c"
                        break
                    end
                    set seen_pkg "$c"
                    set seen_ver "$v"
                end
                if test -n "$srcinfo"
                    break
                end
            end
            if test -z "$srcinfo"
                if test -n "$seen_ver"
                    ui_error "$pkg_name: refusing to build — pkgver was synced to $pkgver-$pkgrel, but the official packaging repo carries $seen_ver"
                    echo "  (read from the .SRCINFO of the official $seen_pkg packaging repo; anchoring to another version's checksums would describe different files)"
                else
                    ui_error "$pkg_name: refusing to build — pkgver was synced to $pkgver-$pkgrel, and the official Arch packaging repo carries no revision of $pkgbase at that version to anchor the checksums to"
                end
                echo "$refuse_manual"
                command rm -rf -- "$tmp"
                return 3
            end
            srcinfo_sum_map "$srcinfo" >"$map"
            set -l map_status $status
            if test $map_status -ne 0; or not test -s "$map"
                ui_error "$pkg_name: refusing to build — the official .SRCINFO for $published does not line its sources up with its checksums, so it cannot be used as an anchor"
                echo "$refuse_manual"
                command rm -rf -- "$tmp"
                return 3
            end
        case aur
            set srcinfo "$provider_file"
            if not test -s "$srcinfo"; or test (srcinfo_pkgbase "$srcinfo") != "$provider_id"; or test (srcinfo_pkgbase "$srcinfo") != "$pkgbase"; or test (srcinfo_pkgver "$srcinfo") != "$pkgver"
                ui_error "$pkg_name: refusing to build — the AUR .SRCINFO for $provider_id does not match pkgbase $pkgbase and pkgver $pkgver"
                echo "$refuse_manual"
                command rm -rf -- "$tmp"
                return 3
            end
            if not srcinfo_matches_sources "$srcinfo" "$pkg_path"
                ui_error "$pkg_name: refusing to build — the AUR .SRCINFO for $provider_id does not cover every source of the rewritten recipe"
                echo "$refuse_manual"
                command rm -rf -- "$tmp"
                return 3
            end
            srcinfo_sum_map "$srcinfo" >"$map"
            set -l map_status $status
            if test $map_status -ne 0
                ui_error "$pkg_name: refusing to build — the AUR .SRCINFO for $provider_id does not line its sources up with its checksums"
                echo "$refuse_manual"
                command rm -rf -- "$tmp"
                return 3
            end
        case github
            set -l tag_file "$tmp/release-tag"
            github_release_checksum_map "$provider_id" "$pkgver" "$tmp" "$map" "$tag_file"
            if test $status -ne 0
                echo "$refuse_manual"
                command rm -rf -- "$tmp"
                return 2
            end
            set release_tag (cat "$tag_file" 2>/dev/null)
        case '*'
            ui_error "$pkg_name: refusing to build — unsupported version sync provider '$provider'"
            command rm -rf -- "$tmp"
            return 2
    end

    # Grade before writing. An entry the provider does not cover cannot be
    # anchored to a published value, so it follows the loud refresh-only path.
    # A published digest is still verified after the write; a disagreement
    # refuses and restores.
    set -l refresh_only
    set -l anchor_index 1
    while test $anchor_index -le (count $anchor_names)
        set -l fn $anchor_names[$anchor_index]
        set -l entry $anchor_entries[$anchor_index]
        if test "$provider" = github
            set -l asset_name (github_release_asset_name "$entry")
            if test -z "$asset_name"; or not github_source_matches_release "$entry" "$provider_id" "$release_tag"
                set -a refresh_only $fn
            else if not grep -qF -- (printf '%s\t' "$asset_name") "$map"
                set -a refresh_only $fn
            end
        else if not grep -qF -- (printf '%s\t' $fn) "$map"
            set -a refresh_only $fn
        end
        set anchor_index (math $anchor_index + 1)
    end

    if not cp -- "$pkg_path/PKGBUILD" "$tmp/PKGBUILD.orig"
        ui_error "$pkg_name: cannot back up $pkg_path/PKGBUILD before refreshing the checksums"
        command rm -rf -- "$tmp"
        return 2
    end

    # Write with makepkg's own updater: it preserves the recipe's formatting and
    # keeps whatever checksum algorithm the recipe already uses, and it is also
    # what fetches the sources that step 2 below then verifies.
    if not pushd "$pkg_path" >/dev/null
        ui_error "$pkg_name: cannot enter $pkg_path to refresh the checksums"
        command rm -rf -- "$tmp"
        return 2
    end
    # updpkgsums shells out to makepkg, which refuses to run as root (it exits
    # 10 before it touches the sums). Root mode therefore drops to the invoking
    # user for this step too — the recipe tree is theirs, not root's.
    set -l run_as env
    if test "$_ROOT_MODE" = "1"
        set run_as sudo -u "$_BUILD_USER" env HOME=$_BUILD_HOME
    end
    $run_as updpkgsums >"$tmp/updpkgsums.log" 2>&1
    set -l upd_rc $status
    popd >/dev/null
    if test "$upd_rc" -ne 0
        set -l restore_note "the recipe was restored"
        set -l restore_failed 0
        if not restore_pkgbuild_snapshot "$pkg_path" "$tmp/PKGBUILD.orig"
            set restore_note "the recipe could NOT be restored and is left rewritten — do not commit it"
            set restore_failed 1
        end
        ui_error "$pkg_name: refusing to build — 'updpkgsums' could not refresh the checksums (exit $upd_rc); $restore_note"
        tail -5 "$tmp/updpkgsums.log" 2>/dev/null | sed 's/^/  /'
        echo "$refuse_manual"
        command rm -rf -- "$tmp"
        if test $restore_failed -eq 1
            return 5
        end
        return 2
    end

    # Verify the fetched sources against the provider's values. This is the step
    # that makes the refresh an anchor rather than a rubber stamp, and it is why
    # the algorithm does not have to match: the published hash is checked
    # against the artifact, and the artifact is what the recipe's own hash now
    # describes.
    # A VCS checkout is hashed the way makepkg hashes it (git archive of the
    # tag), because there is no file to run sha256sum on.
    set -l bad
    # A failure here can be an ABSENCE (source not fetched / VCS checkout
    # unavailable — the anchor is unverifiable) or a DISAGREEMENT (the fetched
    # bytes hash differently — a different source). Only disagreements are fatal.
    set -l environmental_only 1
    for i in (seq (count $anchor_names))
        set -l fn $anchor_names[$i]
        # Refresh-only entries have no published value to compare against —
        # they were recorded as fetch-only above; only anchored entries are
        # verified against the selected provider here.
        if contains -- $fn $refresh_only
            continue
        end
        set -l e $anchor_entries[$i]
        set -l map_name "$fn"
        if test "$provider" = github
            set map_name (github_release_asset_name "$e")
        end
        set -l alg (awk -F'\t' -v f="$map_name" '$1==f{print $2}' "$map")
        set -l want (awk -F'\t' -v f="$map_name" '$1==f{print $3}' "$map")
        if not contains -- $alg sha256 sha512 md5 b2
            set -a bad "$fn: $checksum_owner publishes an algorithm this check does not know ('$alg')"
            set environmental_only 0
            continue
        end
        set -l got ""
        if source_vcs $e >/dev/null
            set got (vcs_source_sum "$pkg_path" "$e" "$alg")
            switch $status
                case 1
                    set -a bad "$fn: the VCS checkout was not available to recompute $checksum_owner's $alg against"
                    continue
                case 2
                    set -a bad "$fn: 'git archive' could not reproduce the $alg $checksum_owner publishes for this checkout"
                    set environmental_only 0
                    continue
            end
        else
            set -l file ""
            if test -f "$pkg_path/$fn"
                set file "$pkg_path/$fn"
            else if set -q SRCDEST; and test -n "$SRCDEST"; and test -f "$SRCDEST/$fn"
                set file "$SRCDEST/$fn"
            end
            if test -z "$file"
                set -a bad "$fn: not fetched into the recipe or \$SRCDEST, so $checksum_owner's checksum could not be applied to it"
                continue
            end
            set got (command "$alg"sum "$file" | string replace -r '\s+.*$' '')
        end
        if test "$got" != "$want"
            set -a bad "$fn: $checksum_owner's $alg is $want, the fetched source hashes to $got"
            set environmental_only 0
        end
    end
    if test (count $bad) -gt 0
        set -l restore_note "the recipe was restored"
        set -l restore_failed 0
        if not restore_pkgbuild_snapshot "$pkg_path" "$tmp/PKGBUILD.orig"
            set restore_note "the recipe could NOT be restored and is left rewritten — do not commit it"
            set restore_failed 1
        end
        if test $environmental_only -eq 1
            # Every entry is an absence, not a disagreement: the anchor could not
            # be checked because the source never arrived. Owner semantics
            # (2026-10-03): park when the consumer chain can absorb the wait, else
            # fall back to a normal build attempt (makepkg fetches and verifies
            # against the recipe sums itself). Never fail-fast on a reconcilable
            # fetch hazard — except over a dirty recipe, which nothing may build
            # or park (2026-10-05).
            printf '  %s\n' $bad
            if test $restore_failed -eq 1
                ui_error "$pkg_name: sources absent at anchoring time, and $restore_note; refusing to proceed over a dirty recipe"
                command rm -rf -- "$tmp"
                return 5
            end
            switch (unverifiable_defer_plan (basename "$pkg_path"))
                case defer
                    set -g _DEFER_REASON source-unfetchable
                    ui_error "$pkg_name: sources absent at anchoring time — consumer chain can absorb the wait — parking this recipe (deferred)"
                    echo "  Nothing was built or installed; dependents wait (waits-on-deferred)."
                    command rm -rf -- "$tmp"
                    return $lane_outcome_defer
                case '*'
                    ui_error "$pkg_name: sources absent at anchoring time — consumers cannot wait — falling back to a normal build attempt (makepkg fetches; the official-anchor check is skipped this run)"
            end
            command rm -rf -- "$tmp"
            return 3
        end
        if test "$provider" = arch
            ui_error "$pkg_name: refusing to build — a source does not match the official Arch checksum"
            printf '  %s\n' $bad
            echo "  Nothing was built or installed and $restore_note. A source that disagrees with Arch's published checksum is a different source, not a stale sum."
        else
            ui_error "$pkg_name: refusing to build — a source does not match the $checksum_owner published checksum"
            printf '  %s\n' $bad
            echo "  Nothing was built or installed and $restore_note. A source that disagrees with $checksum_owner's published checksum is a different source, not a stale sum."
        end
        command rm -rf -- "$tmp"
        if test $restore_failed -eq 1
            return 5
        end
        return 4
    end

    # Refresh-only entries: say so, here and at run level. This is what keeps
    # the refresh from being a silent weakening — the sums describe what the
    # fetch delivered, so the log names every such entry and what stands behind
    # it, and the run summary (synced.list → print_synced_notes) carries the
    # review/commit instruction to the owner.
    set -l n_refresh (count $refresh_only)
    set -l n_anchored (math (count $anchor_names) - $n_refresh)
    if test $n_refresh -gt 0
        ui_warning "$pkg_name: $authority_phrase $published $pkgver publishes no checksum for (refreshed from the fetch, NOT anchored):"
        printf '  %s\n' $refresh_only
        echo "  Attestation: a detached signature is PGP-verified against the anchored payload at build time, a VCS source is pinned by its #tag/#commit, and a plain download is attested by nothing but the fetch (TLS). Review these sums before committing; '--no-sync' builds the committed version as-is."
    end

    refresh_package_srcinfo "$pkg_path" "the source checksums were updated"
    set -l srcinfo_refresh_status $status

    if test $n_anchored -gt 0
        ui_info "$pkg_name: checksums re-anchored to $authority_phrase $published $pkgver checksums, and verified against the fetched sources"
    else
        ui_info "$pkg_name: checksums refreshed for $pkgver — $authority_phrase $published publishes no checksum for any moved source"
    end
    set -l synced_note "$pkg_name: checksums re-anchored to $authority_phrase $published $pkgver"
    if test $n_refresh -gt 0
        set synced_note "$pkg_name: checksums refreshed at $pkgver — $n_anchored anchored to $authority_phrase $published, $n_refresh refresh-only (fetch-only sums: review before committing)"
    end
    if test $srcinfo_refresh_status -ne 0
        set synced_note "$synced_note — the committed .SRCINFO could NOT be refreshed; regenerate it with 'makepkg --printsrcinfo' before committing"
    end
    printf '%s\n' "$synced_note" >>"$_STATE_DIR/synced.list" 2>/dev/null
    command rm -rf -- "$tmp"
    return 0
end

function anchor_sums_from_official -a pkg_path
    anchor_sums_from_provider "$pkg_path" arch "" "" $argv[2..-1]
end

# ─── The shared .SRCINFO parse (F6) ─────────────────────────────────────────
# srcinfo_rows caches ONE tagged parse of every recipe's committed .SRCINFO —
# the single reader every lint and name lookup consumes, so `--audit` reads
# each file once instead of once per lint (~4.5k sed forks at 653 records).
# Row grammar (one awk pass over the whole workspace, $_PACKAGE_MAP order,
# rows grouped per recipe; the field grammar is the srcinfo_* family's —
# optional leading blanks, `field`, blanks, `=`, blanks, value):
#   B|<id>|<pkgbase>              non-empty names only — every consumer drops
#   N|<id>|<pkgname>              a name-less `pkgname = ` line
#   P|<id>|<handle>|<provides>    handle '' = the pkgbase section (metadata
#   C|<id>|<handle>|<conflicts>   makepkg merges into every output)
#   D|<id>|<field>|<value>        field ∈ depends/makedepends/optdepends/
#                                 checkdepends
# P/C rows KEEP empty values (audit_lint_swap flags them); the consumers that
# treat an empty entry as absent drop them where they always did. The parse
# normalises the odd spacing variants the per-lint sed/regex idioms each
# handled differently (an unindented `provides = x`, `provides=x`, CRLF):
# every real .SRCINFO is makepkg-generated (`\tfield = value`), and the
# fixtures pin the findings text on that shape.
function _srcinfo_rows_cache
    if set -q _SR_ROWS
        return 0
    end
    set -g _SR_ROWS
    set -l files
    for entry in $_PACKAGE_MAP
        set -l fields (string split '|' -- "$entry")
        set -l srcinfo "$SCRIPT_DIR/$fields[2]/.SRCINFO"
        test -f "$srcinfo"; or continue
        set -a files "$fields[1]=$srcinfo"
    end
    test (count $files) -gt 0; or return 0
    # ARGV rewriting in BEGIN is what keeps `id=path` operands from being
    # eaten as awk variable assignments; ids[] then re-derives the recipe id
    # from FILENAME per file.
    set _SR_ROWS (awk '
        BEGIN {
            for (i = 1; i < ARGC; i++) {
                p = index(ARGV[i], "=")
                ids[substr(ARGV[i], p + 1)] = substr(ARGV[i], 1, p - 1)
                ARGV[i] = substr(ARGV[i], p + 1)
            }
        }
        FNR == 1 { id = ids[FILENAME]; handle = "" }
        {
            line = $0
            sub(/\r$/, "", line)
            if (line ~ /^[ \t]*(pkgbase|pkgname)[ \t]*=/) {
                v = line
                sub(/^[ \t]*(pkgbase|pkgname)[ \t]*=[ \t]*/, "", v)
                if (v != "") {
                    if (line ~ /^[ \t]*pkgbase[ \t]*=/) {
                        print "B|" id "|" v
                        handle = ""
                    } else {
                        print "N|" id "|" v
                        handle = v
                    }
                }
                next
            }
            if (line ~ /^[ \t]*provides[ \t]*=/) {
                v = line
                sub(/^[ \t]*provides[ \t]*=[ \t]*/, "", v)
                print "P|" id "|" handle "|" v
                next
            }
            if (line ~ /^[ \t]*conflicts[ \t]*=/) {
                v = line
                sub(/^[ \t]*conflicts[ \t]*=[ \t]*/, "", v)
                print "C|" id "|" handle "|" v
                next
            }
            if (line ~ /^[ \t]*(depends|makedepends|optdepends|checkdepends)[ \t]*=/) {
                f = line
                sub(/[ \t]*=.*/, "", f)
                gsub(/^[ \t]+|[ \t]+$/, "", f)
                v = line
                sub(/^[ \t]*(depends|makedepends|optdepends|checkdepends)[ \t]*=[ \t]*/, "", v)
                print "D|" id "|" f "|" v
                next
            }
        }' $files)
    return 0
end

# srcinfo_rows [TAG] → the shared parse's rows: with TAG the payloads of that
# kind alone (tag prefix stripped), without it every row in recipe order with
# its tag kept (for consumers that walk one recipe's rows together). Callers
# that group per recipe rely on rows being contiguous per recipe id.
function srcinfo_rows
    _srcinfo_rows_cache
    if test (count $argv) -ge 1
        test (count $_SR_ROWS) -gt 0; or return 0
        string match -r -g -- "^$argv[1][|](.*)\$" $_SR_ROWS
    else if test (count $_SR_ROWS) -gt 0
        printf '%s\n' $_SR_ROWS
    end
    return 0
end

# pkgbuild_scan_rows → the shared PKGBUILD parse behind the toolchain lint and
# the audit PGO scan (two forks per recipe before — 653 `grep | grep` pairs):
#   W|<id>|<count>  non-comment lines naming cargo/rustc as bare words
#   G|<id>|1        the recipe names an instrumenting flag
# Same EREs as the greps it replaces, line-counted the same way (grep -c).
function pkgbuild_scan_rows
    if not set -q _PB_ROWS
        set -g _PB_ROWS
        _pkgbuild_scan_build
    end
    if test (count $argv) -ge 1
        test (count $_PB_ROWS) -gt 0; or return 0
        string match -r -g -- "^$argv[1][|](.*)\$" $_PB_ROWS
    else if test (count $_PB_ROWS) -gt 0
        printf '%s\n' $_PB_ROWS
    end
    return 0
end

# _pkgbuild_scan_build → fills _PB_ROWS (called once, from pkgbuild_scan_rows).
function _pkgbuild_scan_build
    set -g _PB_ROWS
    set -l files
    for entry in $_PACKAGE_MAP
        set -l fields (string split '|' -- "$entry")
        set -l pb "$SCRIPT_DIR/$fields[2]/PKGBUILD"
        test -f "$pb"; or continue
        set -a files "$fields[1]=$pb"
    end
    test (count $files) -gt 0; or return 0
    set _PB_ROWS (awk '
        BEGIN {
            for (i = 1; i < ARGC; i++) {
                p = index(ARGV[i], "=")
                ids[substr(ARGV[i], p + 1)] = substr(ARGV[i], 1, p - 1)
                ARGV[i] = substr(ARGV[i], p + 1)
            }
            id = ""
        }
        FNR == 1 {
            if (id != "") print "W|" id "|" w
            if (g) print "G|" id "|1"
            id = ids[FILENAME]
            w = 0
            g = 0
        }
        {
            if ($0 ~ /^[[:space:]]*[^#[:space:]]/ && $0 ~ /(^|[^[:alnum:]_])(cargo|rustc)([^[:alnum:]_]|$)/) w++
            if ($0 ~ /-fprofile-generate|-C ?profile-generate/) g = 1
        }
        END {
            if (id != "") print "W|" id "|" w
            if (g) print "G|" id "|1"
        }' $files)
    return 0
end

