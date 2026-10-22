#!/usr/bin/env bash
set -uo pipefail

# abi-need-check.sh — the FATAL runtime-dependency check, at transaction time.
#
# Why this exists
# ---------------
# Stock Arch/CachyOS packages land against whatever SONAME set their build
# hosts had; on this gsa-maintained host those moves (icu .78 -> .79,
# jsoncpp .27 -> .28, ...) leave the stock binary with DT_NEEDED entries
# nothing resolves. Nothing breaks until the code path is first used —
# measured 2026-10-22 on 45 installed packages. This checker refuses such a
# package AT TRANSACTION TIME while the fix is still a decision.
#
# What it checks (deliberately LOOSE)
# -----------------------------------
# Only FATAL breakage: a DT_NEEDED soname that no file resolves after the
# transaction. It does NOT check symbol versions, versioned provides, or
# pin drift — those degrade features, they do not kill the package (owner's
# scope call, 2026-10-22). The runtime oracle is the FILE SYSTEM, not the
# pacman database: `ld.so` resolves by path, so a declared provide with no
# file behind it is exactly as fatal (the tk `libtk.so` dangling symlink,
# 2026-10-22) and a file with no provide is harmless.
#
# Inputs
# ------
#   tools/abi-need-check.sh [--quiet] [<archive-or-pkgdir>...]
#   tools/abi-need-check.sh --from-names   # names on stdin, archives resolved
#
#   Archives (*.pkg.tar.*) are extracted under $TMPDIR only — inputs are
#   never modified. `--from-names` is the pacman PreTransaction hook shape:
#   alpm passes package NAMES on stdin (measured 2026-10-22 with a probe
#   hook: NeedsTargets + Type=Package + When=PreTransaction), so each name
#   resolves to its newest /var/cache/pacman/pkg/<name>-*.pkg.tar.* download.
#   A name with no cached archive (a `pacman -U` of a file elsewhere) is
#   SKIPPED loudly-but-quietly: the engine gates its own installs.
#
# Findings look like:
#   abi-need-check: qt6-webengine: 'QtWebEngineProcess' needs 'libicuuc.so.78' — no file resolves it (fatal)
#
# Exit status: 0 clean, 1 fatal findings, 2 usage or environment error.
# --quiet suppresses the clean lines; findings are always printed.

usage() {
    sed -n '3,38p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
}

quiet=0
from_names=0
declare -a targets=()
while (($# > 0)); do
    case $1 in
        --quiet) quiet=1 ;;
        --from-names) from_names=1 ;;
        -h | --help) usage ;;
        -*)
            printf 'abi-need-check: unknown argument: %s\n' "$1" >&2
            usage
            ;;
        *) targets+=("$1") ;;
    esac
    shift
done

if ((from_names)) && ((${#targets[@]} > 0)); then
    printf 'abi-need-check: --from-names takes names on stdin, not arguments\n' >&2
    usage
fi
if ((!from_names)) && ((${#targets[@]} == 0)); then
    printf 'abi-need-check: no inputs — pass archives, package roots, or --from-names\n' >&2
    usage
fi
if ! command -v readelf >/dev/null 2>&1; then
    printf 'abi-need-check: readelf is required\n' >&2
    exit 2
fi

# The cache a repo transaction downloads into; --from-names resolution only.
cache_dir=${GSA_ABI_NEED_CHECK_CACHE:-/var/cache/pacman/pkg}

if ((from_names)); then
    while IFS= read -r name; do
        [[ -n $name ]] || continue
        newest=''
        for cand in "$cache_dir/$name"-*.pkg.tar.*; do
            [[ -f $cand ]] || continue
            if [[ -z $newest || $cand -nt $newest ]]; then
                newest=$cand
            fi
        done
        if [[ -z $newest ]]; then
            ((quiet)) ||
                printf 'abi-need-check: %s: skipped (no cached archive — local -U install?)\n' "$name"
            continue
        fi
        targets+=("$newest")
    done
    if ((${#targets[@]} == 0)); then
        exit 0
    fi
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/gsa-abi-need-check.XXXXXX") || exit 2
trap 'rm -rf -- "$scratch"' EXIT

# ── Phase 1: collect what the transaction itself ships ────────────────────
# Resolvable-by-the-transaction means: a payload file carrying the soname,
# or a declared provide naming it. Both are read per package root.
declare -a roots=()
declare -a pkgnames=()
tx_sonames=()
tx_provides=()

for target in "${targets[@]}"; do
    root=''
    if [[ -d $target ]]; then
        root=$target
    elif [[ -f $target ]]; then
        dest="$scratch/$(basename "$target").d"
        mkdir -p "$dest"
        if ! tar -xf "$target" -C "$dest"; then
            printf 'abi-need-check: cannot extract %s\n' "$target" >&2
            exit 2
        fi
        root=$dest
    else
        printf 'abi-need-check: no such input: %s\n' "$target" >&2
        exit 2
    fi
    roots+=("$root")
    name=$(sed -n 's/^pkgname = //p' "$root/.PKGINFO" 2>/dev/null | head -1)
    [[ -n $name ]] || name=$(basename "$target")
    pkgnames+=("$name")

    while IFS= read -r provide; do
        [[ -n $provide ]] || continue
        tx_provides+=("${provide%%=*}")
    done < <(sed -n 's/^provides = //p' "$root/.PKGINFO" 2>/dev/null)

    mapfile -d '' -t payload < <(find "$root" -type f \
        ! -name '.PKGINFO' ! -name '.BUILDINFO' ! -name '.MTREE' ! -name '.CHANGELOG' -print0)
    for file in "${payload[@]+"${payload[@]}"}"; do
        while IFS= read -r soname; do
            [[ -n $soname ]] && tx_sonames+=("$soname")
        done < <(readelf -dW "$file" 2>/dev/null |
            sed -n 's/^.*SONAME.*\[\(.*\)\]$/\1/p')
    done
done

# ── Phase 2: resolve-or-report every DT_NEEDED ───────────────────────────
# Class-aware and dangling-aware: a 64-bit consumer is never satisfied by a
# lib32 basename (audit root cause 1, 2026-10-22) and a dangling symlink is
# not a file (audit root cause 3).
host_resolves() {
    # $1 = soname, $2 = libdirs (colon separated), $3 = elf dir (for $ORIGIN)
    local soname=$1 dir elf_dir=$3 path
    local IFS=':'
    for dir in $2; do
        dir=${dir//\$ORIGIN/$elf_dir}
        dir=${dir//\$\{ORIGIN\}/$elf_dir}
        [[ -n $dir ]] || continue
        path=${dir%/}/$soname
        if [[ -e $path ]]; then
            return 0
        fi
    done
    return 1
}

findings=0
idx=0
for root in "${roots[@]}"; do
    pkg=${pkgnames[$idx]}
    idx=$((idx + 1))

    mapfile -d '' -t payload < <(find "$root" -type f \
        ! -name '.PKGINFO' ! -name '.BUILDINFO' ! -name '.MTREE' ! -name '.CHANGELOG' -print0)
    pkg_findings=0
    pkg_needed=0

    for file in "${payload[@]+"${payload[@]}"}"; do
        dynamic=$(readelf -dW "$file" 2>/dev/null) || continue
        [[ -n $dynamic ]] || continue

        class=$(readelf -hW "$file" 2>/dev/null | sed -n 's/^ *Class: *//p')
        case $class in
            ELF64) default_dirs='/usr/lib:/usr/lib64:/lib:/lib64' ;;
            ELF32) default_dirs='/usr/lib32:/lib32' ;;
            *) continue ;;
        esac
        elf_dir=$(dirname "$file")

        runpath=$(printf '%s\n' "$dynamic" |
            sed -n 's/^.*R\(UN\)\?PATH.*\[\(.*\)\]$/\2/p' | head -1)
        libdirs=$default_dirs
        [[ -n $runpath ]] && libdirs=$runpath:$libdirs

        while IFS= read -r needed; do
            [[ -n $needed ]] || continue
            # vDSO is never a file; the loader is, and lives in libdirs.
            [[ $needed == linux-vdso.so* ]] && continue
            pkg_needed=$((pkg_needed + 1))

            covered=0
            for shipped in ${tx_sonames[@]+"${tx_sonames[@]}"}; do
                if [[ $needed == "$shipped" ]]; then
                    covered=1
                    break
                fi
            done
            if ((covered == 0)); then
                for name in ${tx_provides[@]+"${tx_provides[@]}"}; do
                    if [[ $needed == "$name" || $needed == "$name".* ]]; then
                        covered=1
                        break
                    fi
                done
            fi
            if ((covered == 0)) && host_resolves "$needed" "$libdirs" "$elf_dir"; then
                covered=1
            fi

            if ((covered == 0)); then
                printf "abi-need-check: %s: '%s' needs '%s' — no file resolves it (fatal)\n" \
                    "$pkg" "$(basename "$file")" "$needed"
                pkg_findings=$((pkg_findings + 1))
            fi
        done < <(printf '%s\n' "$dynamic" |
            sed -n 's/^.*NEEDED.*\[\(.*\)\]$/\1/p')
    done

    findings=$((findings + pkg_findings))
    ((quiet)) || [[ $pkg_findings -gt 0 ]] ||
        printf 'abi-need-check: %s: clean (%d runtime link(s))\n' "$pkg" "$pkg_needed"
done

if ((findings)); then
    exit 1
fi
exit 0
