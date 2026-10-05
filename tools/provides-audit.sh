#!/usr/bin/env bash
set -uo pipefail

# provides-audit.sh — the soname-provides PRESENCE rule, at artifact level.
#
# Why this exists
# ---------------
# A library-shipping package must declare a bare soname provide (`libfoo.so`)
# for every DT_SONAME it ships: an undeclared soname leaves repo consumers
# unable to resolve the library from this workspace at all. The workspace
# audit lint (lib/audit.fish `audit_lint_provides`) owns the companion FORM
# rule — declare the bare stem so makepkg auto-versions it from the built ELF
# — but form is only checkable from recipe metadata. PRESENCE is a property of
# the built payload, so it is checked here, against the artifact itself.
#
# The two-adapter pairing: this tool is a host-side diagnostic and
# deliberately outside tests/ (it reads real built archives);
# tests/provides-audit.sh pins its contract at reduced scale against
# synthetic packages under $TMPDIR. One rule, one implementation each:
# form lives in the audit lint, presence lives here.
#
# Usage:
#   tools/provides-audit.sh [--quiet] <archive-or-pkgdir>...
#
#   Each argument is a built package archive (*.pkg.tar.*) or an unpacked
#   package root containing .PKGINFO. Archives are extracted under $TMPDIR
#   only — inputs are never modified.
#
# Findings look like:
#   provides-audit: libfoo: soname 'libfoo.so.1' is not declared in provides — declare the bare stem 'libfoo.so'
#
# Exit status: 0 clean, 1 presence findings, 2 usage or environment error.
# --quiet suppresses the clean lines (the battery and scripts use it);
# findings are always printed.

usage() {
    sed -n '3,36p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
}

quiet=0
declare -a targets=()
while (($# > 0)); do
    case $1 in
        --quiet) quiet=1 ;;
        -h | --help) usage ;;
        -*)
            printf 'provides-audit: unknown argument: %s\n' "$1" >&2
            usage
            ;;
        *) targets+=("$1") ;;
    esac
    shift
done
if ((${#targets[@]} == 0)); then
    printf 'provides-audit: no inputs — pass package archives or package roots\n' >&2
    usage
fi
if ! command -v readelf >/dev/null 2>&1; then
    printf 'provides-audit: readelf is required\n' >&2
    exit 2
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/gsa-provides-audit.XXXXXX") || exit 2
trap 'rm -rf -- "$scratch"' EXIT

findings=0

for target in "${targets[@]}"; do
    root=''
    if [[ -d $target ]]; then
        root=$target
    elif [[ -f $target ]]; then
        dest="$scratch/$(basename "$target").d"
        mkdir -p "$dest"
        if ! tar -xf "$target" -C "$dest"; then
            printf 'provides-audit: cannot extract %s\n' "$target" >&2
            exit 2
        fi
        root=$dest
    else
        printf 'provides-audit: no such input: %s\n' "$target" >&2
        exit 2
    fi
    if [[ ! -f $root/.PKGINFO ]]; then
        printf 'provides-audit: %s has no .PKGINFO — not a package payload\n' "$target" >&2
        exit 2
    fi

    pkgname=$(sed -n 's/^pkgname = //p' "$root/.PKGINFO" | head -1)
    [[ -n $pkgname ]] || pkgname=$(basename "$target")

    declared=()
    while IFS= read -r provide; do
        [[ -n $provide ]] || continue
        declared+=("${provide%%=*}")
    done < <(sed -n 's/^provides = //p' "$root/.PKGINFO")

    # Every DT_SONAME the payload ships, whatever file carries it — scoping
    # to usr/lib would embed an assumption about where a recipe installs.
    mapfile -d '' -t payload_files < <(find "$root" -type f ! -name '.PKGINFO' ! -name '.BUILDINFO' ! -name '.MTREE' ! -name '.CHANGELOG' -print0)
    sonames=$(for file in "${payload_files[@]+"${payload_files[@]}"}"; do
        readelf -dW "$file" 2>/dev/null |
            sed -n 's/^.*SONAME.*\[\(.*\)\]$/\1/p'
    done | sort -u)

    if [[ -z $sonames ]]; then
        ((quiet)) || printf 'provides-audit: %s: clean (no shipped sonames)\n' "$pkgname"
        continue
    fi

    while IFS= read -r soname; do
        [[ -n $soname ]] || continue
        covered=0
        for name in ${declared[@]+"${declared[@]}"}; do
            # Presence only: the declared name may be the bare stem or the
            # full soname — which of those it SHOULD be is the lint's rule.
            if [[ $soname == "$name" || $soname == "$name".* ]]; then
                covered=1
                break
            fi
        done
        if ((covered == 0)); then
            stem=${soname%%.so*}
            printf "provides-audit: %s: soname '%s' is not declared in provides — declare the bare stem '%s'\n" \
                "$pkgname" "$soname" "${stem}.so"
            findings=$((findings + 1))
        fi
    done <<<"$sonames"
    ((quiet)) ||
        printf 'provides-audit: %s: clean (%d soname(s))\n' "$pkgname" "$(wc -l <<<"$sonames")"
done

if ((findings)); then
    exit 1
fi
exit 0
