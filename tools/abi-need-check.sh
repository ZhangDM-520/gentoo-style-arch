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
#   alpm feeds bare package NAMES on stdin, one per line and NO versions
#   (lib/libalpm/hook.c `_alpm_hook_feed_targets` writes `pkg->name`;
#   measured 2026-10-22 with a probe hook: NeedsTargets + Type=Package +
#   When=PreTransaction). A cached archive is therefore only verifiably the
#   payload of a SYNC transaction — a same-name stale twin cannot be told
#   apart from the file being installed by name alone. The stand-down is
#   NOT cache-conditioned: a local file install (the pacman argv of the
#   transaction carries `-U`, read from the process ancestry) SKIPS every
#   name outright — cached twin or not — because the engine gates its own
#   installs (2026-10-25: weston/colord's archives had to be moved out of
#   the cache by hand to buy this). A sync name resolves to its newest
#   cached ARCHIVE — the archive pacman is actually installing — real
#   package extensions only; the detached `…pkg.tar.zst.sig` siblings share
#   the name glob but are never candidates (regression 2026-10-22). A name
#   with no cached archive is SKIPPED loudly-but-quietly the same way. An
#   input that fails to extract is warned
#   about and SKIPPED too — pacman's integrity checks already passed it, so
#   failing the transaction on a check we could not perform is a false
#   alarm; real findings stay fatal.
#
#   Kernel-class names (kernel flavours, firmware — see kernel_class()) are
#   skipped outright: their payloads carry no userspace DT_NEEDED surface.
#   ELF facts are parsed in BATCHED readelf passes (spawn count is the
#   whole cost — profiled 2026-10-22) and cached per archive content hash
#   (facts only, never verdicts; see $GSA_ABI_NEED_CHECK_FACTCACHE).
#
# Findings look like:
#   abi-need-check: qt6-webengine: 'QtWebEngineProcess' needs 'libicuuc.so.78' — no file resolves it (fatal)
#
# Exit status: 0 clean, 1 fatal findings, 2 usage or environment error.
# --quiet suppresses the clean lines; findings are always printed.

usage() {
    sed -n '3,/^usage() {/p' "$0" | sed '$d; s/^# \{0,1\}//'
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

# Kernel-class payloads carry no userspace dynamically-linked ELF — vmlinuz
# and ET_REL modules only — so they cannot exhibit the userspace SONAME
# skew this gate exists for (owner's optimisation call, 2026-10-22). The
# invariant to keep honest: ONLY kernel/flavour and firmware payloads
# qualify. `linux-cachyos-headers` carries 22 real runtime links (measured
# 2026-10-22) and stays scannable; if a listed package ever grows a
# userspace ELF, it leaves this list.
#
# The flavour roster is EXPLICIT names, never a `linux-*` wildcard: the old
# wildcard swallowed real userspace payloads (`linux-tools` ships
# perf/turbostat, `linux-atm` its own daemons — config/topology.conf:91
# carries linux-tools' edges). Enumerated literally from the repo's kernel
# recipe (packages/misc/linux-cachyos; tests/kernel-recipes.sh pins that
# one recipe) plus the flavour names this host actually transacts
# (`pacman -Q linux*`, each vmlinuz + modules with no userspace DT_NEEDED
# surface, 2026-10-28). A name joins this list the day its payload is
# verified kernel-class and leaves it the day it grows a userspace ELF.
kernel_class() {
    case $1 in
        *-headers | *-src | *-dkms) return 1 ;;
        linux | linux-cachyos | linux-cachyos-lts | linux-cachyos-bore-lto | \
            linux-cachyos-bore-lto-dbg)
            return 0
            ;;
        *-firmware) return 0 ;;
    esac
    return 1
}

# file_install_txn — is the transaction behind this run a local FILE
# install? alpm feeds bare names (no versions), so the only witness to the
# transaction shape is the pacman process that spawned this hook: walk up
# the process ancestry for it and read its argv. `pacman -U <files>`
# (single-dash clusters containing `U`; `-Syu`'s `u` is lowercase and never
# matches) installs the named FILES and must STAND DOWN — the cached
# same-name twin is not the payload. A sync argv (`-S…`) — or no pacman
# ancestor at all, the standalone/test shape — installs from the cache,
# where the cached archive IS the payload.
file_install_txn() {
    local pid=$PPID depth=0 arg
    local -a argv
    while ((depth < 16)) && [[ -n ${pid:-} && $pid -gt 1 && -r /proc/$pid/cmdline ]]; do
        argv=()
        while IFS= read -r -d '' arg; do argv+=("$arg"); done <"/proc/$pid/cmdline"
        if ((${#argv[@]} > 0)) && [[ ${argv[0]##*/} == pacman ]]; then
            for arg in "${argv[@]:1}"; do
                # `pacman --upgrade <file>` is the same file-install witness
                # as `-U` (S3: the stand-down must see the long spelling too
                # — skipping `--*` wholesale classed it as a sync).
                [[ $arg == --upgrade ]] && return 0
                [[ $arg == --* ]] && continue
                [[ $arg == -*U* ]] && return 0
            done
            return 1
        fi
        pid=$(sed -n 's/^PPid:[[:space:]]*//p' "/proc/$pid/status" 2>/dev/null)
        depth=$((depth + 1))
    done
    return 1
}

if ((from_names)); then
    file_install=0
    file_install_txn && file_install=1
    while IFS= read -r name; do
        [[ -n $name ]] || continue
        if ((file_install)); then
            ((quiet)) ||
                printf 'abi-need-check: %s: skipped (local file install — the engine gates its own installs)\n' "$name"
            continue
        fi
        if kernel_class "$name"; then
            ((quiet)) ||
                printf 'abi-need-check: %s: skipped (kernel-class payload — no userspace ABI surface)\n' "$name"
            continue
        fi
        newest=''
        for cand in "$cache_dir/$name"-*.pkg.tar.*; do
            [[ -f $cand ]] || continue
            # Real package archives only. The detached PGP signature
            # (…pkg.tar.zst.sig) and any other sibling share the name glob
            # but are not archives — regression 2026-10-22: a .sig won the
            # newest-wins race and its extraction aborted a 50-package
            # upgrade. Known makepkg/pacman archive extensions:
            case $cand in
                *.pkg.tar.zst | *.pkg.tar.xz | *.pkg.tar.gz | *.pkg.tar.bz2 | *.pkg.tar.lrz | *.pkg.tar.lzo | *.pkg.tar.Z) ;;
                *) continue ;;
            esac
            # EXACT name, never prefix: `linux-cachyos` must not resolve
            # `linux-cachyos-headers-*` (regression 2026-10-22 replay: the
            # prefix twin won newest-wins and the kernel went unscanned).
            # Archive names are <pkgname>-<pkgver>-<pkgrel>-<arch> and
            # makepkg forbids hyphens in the last three fields
            # (lint_pkgbuild: pkgver/pkgrel rules), so splitting from the
            # right is deterministic — reconstruct and compare.
            stem=${cand##*/}
            stem=${stem%.pkg.tar.*}
            rest=${stem#"$name"-}
            arch_part=${rest##*-}
            rest=${rest%-*}
            rel_part=${rest##*-}
            ver_part=${rest%-*}
            if [[ $ver_part == *-* || $rel_part == *-* || $arch_part == *-* ]] ||
                [[ $name-$ver_part-$rel_part-$arch_part != "$stem" ]]; then
                continue
            fi
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

# \u2500\u2500 Phase 1: acquire per-payload facts (one extract, one batched parse) \u2500\u2500
# Facts are a payload's ELF surface \u2014 per file: relpath, class, runpath,
# SONAME, DT_NEEDED list \u2014 plus the package's provide names. Facts depend
# on the ARCHIVE only, never on host state, so they cache by content hash;
# the resolve-or-report VERDICT is always computed fresh against the host.
#
# Cost anatomy (profiled 2026-10-22 on the 159 MB kernel archive): extract
# 0.07 s, per-file readelf spawns 21.9 s, BATCHED readelf 0.056 s \u2014 the
# spawn count is the entire cost. So: chunked multi-file readelf, never a
# per-file spawn, and no per-file sed/subshell drains.
US=$'\x1f'
RS=$'\x1e'

# readelf_facts ROOT SOLE RELPATH... \u2014 one batched `readelf -hW -dW` over
# the chunk, run with cwd=ROOT so `File:` markers carry relpaths. Emits one
# record per ELF file:
#   file<US>relpath<US>class<US>runpath<US>soname<US>needed<RS>needed\u2026
# Non-ELF payloads emit nothing (readelf prints no `File:` marker for
# them); readelf's single-file output carries NO marker at all, so SOLE
# names the file in that case (measured 2026-10-22).
readelf_facts() {
    local root=$1 sole=$2
    shift 2
    (cd "$root" && readelf -hW -dW "$@" 2>/dev/null) |
        awk -v sole="$sole" -v sUS="$US" -v sRS="$RS" '
            function emit() {
                if (cur == "") return
                printf "file%s%s%s%s%s%s%s%s%s%s\n", sUS, cur, sUS, cls, sUS, rp, sUS, son, sUS, nd
            }
            /^File: / {
                emit()
                cur = substr($0, 7)
                cls = rp = son = nd = ""
                marked = 1
                next
            }
            /Class: *ELF/ { cls = $2; next }
            /\(SONAME\)/ {
                if (match($0, /\[[^]]*\]/)) son = substr($0, RSTART + 1, RLENGTH - 2)
                next
            }
            /\((RUNPATH|RPATH)\)/ {
                if (rp == "" && match($0, /\[[^]]*\]/)) rp = substr($0, RSTART + 1, RLENGTH - 2)
                next
            }
            /\(NEEDED\)/ {
                if (match($0, /\[[^]]*\]/)) {
                    v = substr($0, RSTART + 1, RLENGTH - 2)
                    nd = (nd == "" ? v : nd sRS v)
                }
            }
            END {
                if (!marked) cur = sole
                emit()
            }
        '
}

# Fact cache: one file per archive content hash under
# ${GSA_ABI_NEED_CHECK_FACTCACHE:-/var/cache/gsa-abi-need-check}. Only the
# PARSE is cached \u2014 the archive is still extracted every run because the
# resolution oracle is the file system and includes the payload tree itself
# ($ORIGIN runpath lookups, rule 25(b)). Verdicts are never cached.
factcache_dir=${GSA_ABI_NEED_CHECK_FACTCACHE:-/var/cache/gsa-abi-need-check}
factcache_ok=0
mkdir -p "$factcache_dir" 2>/dev/null &&
    [[ -d $factcache_dir && -w $factcache_dir ]] && factcache_ok=1

declare -a roots=()
declare -a pkgnames=()
declare -a factblobs=()
tx_sonames=()
tx_provides=()

for target in "${targets[@]}"; do
    root=''
    blob=''
    sha=''
    if [[ -d $target ]]; then
        root=$target
    elif [[ -f $target ]]; then
        sha=$(sha256sum "$target")
        sha=${sha%% *}
        root="$scratch/$(basename "$target").d"
        mkdir -p "$root"
        if ! tar -xf "$target" -C "$root" 2>/dev/null; then
            # FAIL OPEN on an unextractable input. pacman's keyring and
            # integrity checks have already passed this archive before
            # hooks run, so an extraction failure here is a pipeline
            # problem (a signature or foreign file slipping past the name
            # filter, a tar without the codec) \u2014 not evidence about the
            # package. Blocking the transaction on a check we could not
            # perform IS the false alarm (regression 2026-10-22). Real
            # findings below stay fatal.
            printf 'abi-need-check: %s: skipped (not extractable)\n' \
                "$(basename "$target")" >&2
            continue
        fi
        if ((factcache_ok)) && [[ -s $factcache_dir/$sha.facts ]] &&
            [[ $(head -1 "$factcache_dir/$sha.facts") == "# gsa-abi-need-check facts v1 $sha" ]]; then
            blob=$(sed '1d' "$factcache_dir/$sha.facts")
        fi
    else
        printf 'abi-need-check: no such input: %s\n' "$target" >&2
        exit 2
    fi

    if [[ -z $blob ]]; then
        name=$(sed -n 's/^pkgname = //p' "$root/.PKGINFO" 2>/dev/null | head -1)
        [[ -n $name ]] || name=$(basename "$target")
        blob="pkg${US}${name}"$'\n'
        while IFS= read -r provide; do
            [[ -n $provide ]] || continue
            blob+="prov${US}${provide%%=*}"$'\n'
        done < <(sed -n 's/^provides = //p' "$root/.PKGINFO" 2>/dev/null)

        mapfile -d '' -t payload < <(find "$root" -type f \
            ! -name '.PKGINFO' ! -name '.BUILDINFO' ! -name '.MTREE' ! -name '.CHANGELOG' -print0)
        i=0
        np=${#payload[@]}
        while ((i < np)); do
            chunk=()
            while ((i < np)) && ((${#chunk[@]} < 1500)); do
                chunk+=("${payload[$i]#"$root"/}")
                i=$((i + 1))
            done
            blob+=$(readelf_facts "$root" "${chunk[0]}" "${chunk[@]}")$'\n'
        done

        if [[ -n $sha ]] && ((factcache_ok)); then
            { printf '# gsa-abi-need-check facts v1 %s\n' "$sha"; printf '%s' "$blob"; } \
                >"$factcache_dir/$sha.facts.tmp" 2>/dev/null &&
                mv "$factcache_dir/$sha.facts.tmp" "$factcache_dir/$sha.facts" 2>/dev/null
        fi
    fi

    # Transaction-internal surface: provide names and shipped sonames of
    # EVERY package in the batch (coverage crosses package boundaries).
    name=''
    while IFS= read -r line; do
        case $line in
            "pkg"$'\x1f'*)
                [[ -n $name ]] || name=${line#*"$US"}
                ;;
            "prov"$'\x1f'*)
                tx_provides+=("${line#*"$US"}")
                ;;
            "file"$'\x1f'*)
                rest=${line#*"$US"}
                rest=${rest#*"$US"}
                rest=${rest#*"$US"}
                rest=${rest#*"$US"}
                son=${rest%%"$US"*}
                [[ -n $son ]] && tx_sonames+=("$son")
                ;;
        esac
    done <<<"$blob"

    roots+=("$root")
    pkgnames+=("${name:-$(basename "$target")}")
    factblobs+=("$blob")
done

# Nothing scannable in explicit mode is a caller problem (every input was
# foreign or corrupt); --from-names already exited 0 for an empty set.
if ((!from_names)) && ((${#roots[@]} == 0)); then
    printf 'abi-need-check: no input could be scanned\n' >&2
    exit 2
fi

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
    blob=${factblobs[$idx]}
    idx=$((idx + 1))
    pkg_findings=0
    pkg_needed=0

    while IFS= read -r line; do
        [[ $line == "file"$US* ]] || continue
        rest=${line#*"$US"}
        relpath=${rest%%"$US"*}
        rest=${rest#*"$US"}
        class=${rest%%"$US"*}
        rest=${rest#*"$US"}
        runpath=${rest%%"$US"*}
        rest=${rest#*"$US"}
        # field 4 is the soname (already in tx_sonames); the tail is the
        # RS-joined DT_NEEDED list.
        needed_blob=${rest#*"$US"}

        case $class in
            ELF64) default_dirs='/usr/lib:/usr/lib64:/lib:/lib64' ;;
            ELF32) default_dirs='/usr/lib32:/lib32' ;;
            *) continue ;;
        esac
        elf_dir=$root
        [[ $relpath == */* ]] && elf_dir="$root/${relpath%/*}"
        libdirs=$default_dirs
        [[ -n $runpath ]] && libdirs=$runpath:$libdirs

        nb=$needed_blob
        while [[ -n $nb ]]; do
            if [[ $nb == *"$RS"* ]]; then
                needed=${nb%%"$RS"*}
                nb=${nb#*"$RS"}
            else
                needed=$nb
                nb=''
            fi
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
                        # The runtime oracle is the FILE SYSTEM, not the
                        # pacman database: a provide-name match covers a
                        # stem only when a real file stands behind the
                        # needed name — the SAME resolution the direct
                        # (non-provide) hit path performs. A declared
                        # provide with no file behind it (the tk `libtk.so`
                        # dangling symlink, 2026-10-22) is exactly as fatal
                        # as no provide at all and must NOT set covered.
                        if host_resolves "$needed" "$libdirs" "$elf_dir"; then
                            covered=1
                        fi
                        break
                    fi
                done
            fi
            if ((covered == 0)) && host_resolves "$needed" "$libdirs" "$elf_dir"; then
                covered=1
            fi

            if ((covered == 0)); then
                printf "abi-need-check: %s: '%s' needs '%s' — no file resolves it (fatal)\n" \
                    "$pkg" "${relpath##*/}" "$needed"
                pkg_findings=$((pkg_findings + 1))
            fi
        done
    done <<<"$blob"

    findings=$((findings + pkg_findings))
    ((quiet)) || [[ $pkg_findings -gt 0 ]] ||
        printf 'abi-need-check: %s: clean (%d runtime link(s))\n' "$pkg" "$pkg_needed"
done

if ((findings)); then
    exit 1
fi
exit 0
