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
# pacman database: `ld.so` resolves by path — the consumer's RUNPATH, the
# default lib dirs, and the loader cache (`ldconfig -p`: ld.so.conf.d dirs
# and filename-indexed libraries, R's libR.so class) — so a declared
# provide with no file behind it is exactly as fatal (the tk `libtk.so`
# dangling symlink, 2026-10-22) and a file with no provide is harmless.
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
#   abi-need-check: gsa-owned provider behind: icu-git
#
# The second line is ATTRIBUTION, printed once at the end and only when the
# run has findings: the missing soname's family stem is looked up in the
# side-car binpkg index (${GSA_STATE_DIR:-/var/lib/gsa}/index/binpkg.jsonl,
# overridable with $GSA_ABI_NEED_CHECK_BINPKG, one pass, names only). It
# answers the question the fatal line leaves open — whether the provider is a
# gsa-managed package the tree is behind on, the 2026-11-10 openssl 3.6.5 vs
# core 4.1.0 case — without spawning gsa or pacman. A clean transaction
# collects no stems and therefore reads no index.
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
# The same shipped names WITH their ELF class: the drop test is class-scoped
# (a 64-bit consumer is never covered by a 32-bit ship of the same soname).
declare -A tx_shipped_class=()
# Shipped names whose class could not be resolved (a link whose target is not
# in the same payload): coverage is class-blind for those, as before.
declare -A tx_ships_any=()

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
            [[ $(head -1 "$factcache_dir/$sha.facts") == "# gsa-abi-need-check facts v3 $sha" ]]; then
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

        # A payload SYMLINK is a loader name of its own: a versioned DSO
        # shipped as `libaaf.so -> libaaf.so.0.0.0` (ardour, issue #2) is
        # recorded by consumers as `NEEDED libaaf.so`, a name the regular
        # file does not have. `find -type f` never yields it, so it takes a
        # second pass, and the link only names a real payload ELF when its
        # resolved target IS one — a link out of the tree, a dangling link
        # (never resolution: the tk `libtk.so` lesson) and a link to a data
        # file all stay out of the cover set.
        declare -A elf_rel=() elf_cls=()
        link=''
        while IFS= read -r line; do
            [[ $line == "file"$US* ]] || continue
            rest=${line#*"$US"}
            rel=${rest%%"$US"*}
            rest=${rest#*"$US"}
            elf_rel[$rel]=1
            elf_cls[$rel]=${rest%%"$US"*}
        done <<<"$blob"
        while IFS= read -r -d '' link; do
            target=$(readlink -f -- "$link" 2>/dev/null) || continue
            [[ -n $target && $target == "$root"/* ]] || continue
            [[ -n ${elf_rel[${target#"$root"/}]:-} ]] || continue
            # The LINK's class is its target's: a symlink is not an ELF, but
            # the loader name it carries resolves to one, and coverage is
            # class-scoped (a 64-bit need is never covered by a 32-bit ship).
            blob+="link${US}${link#"$root"/}${US}${elf_cls[${target#"$root"/}]:-}"$'\n'
        done < <(find "$root" -type l \
            ! -name '.PKGINFO' ! -name '.BUILDINFO' ! -name '.MTREE' ! -name '.CHANGELOG' -print0)

        if [[ -n $sha ]] && ((factcache_ok)); then
            { printf '# gsa-abi-need-check facts v3 %s\n' "$sha"; printf '%s' "$blob"; } \
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
                relpath=${rest%%"$US"*}
                rest=${rest#*"$US"}
                class=${rest%%"$US"*}
                rest=${rest#*"$US"}
                rest=${rest#*"$US"}
                son=${rest%%"$US"*}
                [[ -n $son ]] && tx_sonames+=("$son")
                # A payload ELF is in this transaction, so its bare FILE name
                # covers exactly as a soname does — the loader is told where
                # that directory is by whoever ships it (a launcher's
                # LD_LIBRARY_PATH, a runpath, a provide), and the gate cannot
                # see a private dir at all. That is the perl case (no
                # DT_SONAME: `NEEDED libperl.so`) and the ardour case (no
                # runpath, libs under usr/lib/ardour9, indexed by `find -type f`
                # but never by the default dirs, the cache, or any runpath);
                # leaving the bare name out aborted every transaction carrying
                # either. The CLASS gate keeps it honest: readelf_facts emits a
                # line for any tracked payload FILE (the resolve loop needs the
                # non-ELF ones to skip), so a data file read
                # `/usr/bin/ardour9` must never cover a loader name.
                # The absolute form too: a path-style NEEDED (`/usr/lib/x`)
                # names the file by its INSTALL path, which is exactly
                # `/$relpath` (issue #3) — that is how a transaction that
                # ships the provider covers its own consumer before the
                # files land.
                case $class in
                    ELF64 | ELF32)
                        tx_sonames+=("${relpath##*/}" "/$relpath")
                        tx_shipped_class["${relpath##*/}|$class"]=1
                        tx_shipped_class["/$relpath|$class"]=1
                        [[ -n $son ]] && tx_shipped_class["$son|$class"]=1
                        ;;
                esac
                ;;
            "link"$'\x1f'*)
                # The LINK's own name is the loader name a consumer records;
                # the file it resolves to keeps its regular-file name above.
                # Its install path covers a path-style NEEDED the same way.
                relpath=${line#*"$US"}
                rest=${relpath#*"$US"}
                relpath=${relpath%%"$US"*}
                link_class=$rest
                tx_sonames+=("${relpath##*/}" "/$relpath")
                if [[ -n $link_class ]]; then
                    tx_shipped_class["${relpath##*/}|$link_class"]=1
                    tx_shipped_class["/$relpath|$link_class"]=1
                else
                    tx_ships_any["${relpath##*/}"]=1
                    tx_ships_any["/$relpath"]=1
                fi
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
# file_elf_class PATH — ELF64|ELF32, or empty when PATH is not an ELF. The
# loader refuses a non-ELF as a shared object, so "not an ELF" resolves
# nothing; the whole read is the 5-byte header (EI_MAG + EI_CLASS).
file_elf_class() {
    local bytes cls
    bytes=$(od -An -tx1 -N5 -- "$1" 2>/dev/null | tr -d ' \n')
    [[ $bytes == 7f454c46* ]] || return 0
    cls=${bytes:8:2}
    case $cls in
        01) printf 'ELF32\n' ;;
        02) printf 'ELF64\n' ;;
    esac
}

host_resolves() {
    # $1 = soname, $2 = libdirs (colon separated), $3 = elf dir (for $ORIGIN)
    # $4 = ELF class (ELF64|ELF32) for the cache fallback
    local soname=$1 dir elf_dir=$3 path class=${4:-ELF64}
    # A PATH-STYLE name is already where the loader will look: a
    # DT_SONAME-less DSO linked by absolute path (`-l/usr/lib/libmujs.so`)
    # records the path itself as DT_NEEDED, and ld.so opens exactly that
    # file — it consults neither the default dirs nor ld.so.cache for a name
    # containing '/'. Prefixing a libdir onto it can only ever miss
    # (`/usr/lib//usr/lib/libmujs.so`), which is issue #3's fatal. Existence
    # plus the consumer's ELF class is the whole answer; an absent path (or a
    # non-ELF/garbage one) stays fatal — that is the vanished-provider case
    # this hook exists for.
    if [[ $soname == /* ]]; then
        [[ -e $soname ]] || return 1
        [[ $(file_elf_class "$soname") == "$class" ]]
        return
    fi
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
    # `ldconfig -p` is the map ld.so itself loads: a row's name is the
    # indexed name (DT_SONAME or bare file name). The class tag must match
    # (audit root cause 1: a 64-bit consumer is never satisfied by a lib32
    # row) and the file must exist (audit root cause 3: a cache row pointing
    # at nothing resolves nothing).
    load_ld_cache
    local entries entry tag
    entries=${ld_cache_by_name[$soname]:-}
    while [[ -n $entries ]]; do
        if [[ $entries == *';'* ]]; then
            entry=${entries%%;*}
            entries=${entries#*;}
        else
            entry=$entries
            entries=''
        fi
        tag=${entry%%|*}
        path=${entry#*|}
        case $class in
        ELF64) [[ $tag == *x86-64* ]] || continue ;;
        ELF32) [[ $tag != *x86-64* ]] || continue ;;
        esac
        if [[ -e $path ]]; then
            return 0
        fi
    done
    return 1
}

# ld.so.cache truth, loaded once (spawn count is the whole cost): the
# loader's search includes the ld.so.conf.d dirs and filename-indexed
# libraries that no dir scan sees (R's libR.so has NO DT_SONAME —
# /usr/lib/R/lib/libR.so is cached under its file name; measured 2026-10-30).
#
# Indexed by NAME into an associative array at first use. The cache runs to
# ~5.8k rows on this host and the earlier shape rescanned EVERY row per
# unresolved soname — measured 2026-11-11: 103 ms per miss against 0.2 ms for
# an array hit, and misses are exactly what a fatal transaction is full of.
# The value is a ';'-joined list of `tag|path` entries (one name may appear
# under several class tags); the per-entry class/file test is unchanged.
ld_cache_loaded=0
declare -A ld_cache_by_name=()
load_ld_cache() {
    ((ld_cache_loaded)) && return 0
    local line name tag arrow path
    while IFS= read -r line; do
        [[ $line == *' => '* ]] || continue
        IFS=$' \t' read -r name tag arrow path <<<"$line" || continue
        [[ $arrow == '=>' ]] || continue
        tag=${tag#\(}
        tag=${tag%\)}
        ld_cache_by_name[$name]+="${ld_cache_by_name[$name]:+;}$tag|$path"
    done < <(ldconfig -p 2>/dev/null)
    ld_cache_loaded=1
}

# The Tier-2 documented-gap registry the install seam already honours
# (`AbiExclusions::covers`, gsa-install/src/gates.rs): an id here is a REVIEWED
# exception to the soname closure rules — a package id, a soname, or its bare
# stem. The gate never read it, so a documented exception still aborted the
# transaction: openimagedenoise's lazy-loaded CUDA backend needs libcuda.so.1,
# which no file on an AMD-only host can resolve BY DESIGN (the registry has
# carried `libcuda.so` since it was seeded), and every `pacman -Syu` died in
# this PreTransaction hook from 2026-11-10 until 2026-11-14 — the installed
# 2.4.1 ships the identical dangling plugin, so the check was refusing a
# condition it had already accepted once.
#
# Searched in the order a hook can actually see: an explicit override
# (fixtures); the state-root copy; the ACTIVE workspace's own checkout; then
# the build user's recipe store via `$SUDO_HOME` (pacman runs this hook as
# root with HOME=/root, so the build user's path needs the sudo variable).
# Absent everywhere means the empty registry — a host with no recipe
# workspace keeps the strict behaviour rather than silently exempting
# anything.
#
# The active workspace sits ABOVE the store on purpose: a checkout edit must
# be testable here before it is shipped, and a store-first order silently
# read the stale copy (issue #2 secondary — the host's /etc/gsa/gsa.conf had
# `project` commented out, so the checkout existed and still lost).
abi_exclusions_file=${GSA_ABI_NEED_CHECK_EXCLUSIONS:-}
abi_ids=()

# `project = <workspace>` from a gsa.conf, read with the engine's own rule
# (a bash `key = value` file, never sourced — sourcing it would run its text).
gsa_conf_project() {
    local conf=$1 value
    [[ -r $conf ]] || return 1
    value=$(sed -n 's/^[[:space:]]*project[[:space:]]*=[[:space:]]*\(.*[^[:space:]]\).*$/\1/p' "$conf" 2>/dev/null | head -1)
    [[ -n $value ]] || return 1
    # `~` expands to the BUILD user's home under sudo; the owner cannot.
    case $value in
        '~'/*) value="${SUDO_HOME:-${HOME:-}}/${value#\~/}" ;;
    esac
    printf '%s\n' "$value"
}

# The engine's own gsa.conf LADDER (gsa_model::config::load): `GSA_CONF`
# replaces the layers with exactly one file, `GSA_CONF_DIR` replaces the
# directory resolution with exactly one directory, otherwise /etc/gsa then the
# build user's ~/.config/gsa merge in that order (the override last, so it
# answers). Mirrored here because the hook is bash and must see the same
# workspace the engine would act on.
gsa_conf_ladder() {
    local conf=$1 dir
    if [[ -n ${GSA_CONF:-} ]]; then
        printf '%s\n' "$GSA_CONF"
        return 0
    fi
    if [[ -n ${GSA_CONF_DIR:-} ]]; then
        [[ -r $GSA_CONF_DIR/$conf ]] && printf '%s\n' "$GSA_CONF_DIR/$conf"
        return 0
    fi
    for dir in /etc/gsa "${SUDO_HOME:-${HOME:-}}/.config/gsa"; do
        [[ -r $dir/$conf ]] && printf '%s\n' "$dir/$conf"
    done
}

load_abi_exclusions() {
    local path=''
    if [[ -n $abi_exclusions_file ]]; then
        path=$abi_exclusions_file
    else
        local candidate project conf
        for candidate in "${GSA_STATE_DIR:-/var/lib/gsa}/abi/exclusions.conf"; do
            [[ -r $candidate ]] && { path=$candidate; break; }
        done
        while IFS= read -r conf; do
            [[ -n $conf ]] || continue
            project=$(gsa_conf_project "$conf") || continue
            candidate="$project/config/abi-exclusions.conf"
            [[ -r $candidate ]] && { path=$candidate; break; }
        done < <(gsa_conf_ladder gsa.conf)
        if [[ -z $path ]]; then
            candidate="${SUDO_HOME:-${HOME:-}}/.local/share/gsa/recipes/config/abi-exclusions.conf"
            [[ -r $candidate ]] && path=$candidate
        fi
    fi
    [[ -n $path && -r $path ]] || return 0
    local line id
    while IFS= read -r line; do
        line=${line#"${line%%[![:space:]]*}"}
        [[ -z $line || $line == '#'* ]] && continue
        [[ $line == *'|'* ]] || continue
        id=${line%%|*}
        id=${id%"${id##*[![:space:]]}"}
        [[ -n $id ]] && abi_ids+=("$id")
    done <"$path"
}

# Same matcher as `AbiExclusions::covers`: the full name (a package id or an
# unversioned soname) first, then the family stem (`libfoo.so.3` -> `libfoo.so`).
abi_excluded() {
    local name=$1 id
    # The registry names libraries (a soname or its stem), never install
    # paths: a path-style loader name is judged by its basename (issue #3).
    [[ $name == /* ]] && name=${name##*/}
    for id in ${abi_ids[@]+"${abi_ids[@]}"}; do
        [[ $id == "$name" ]] && return 0
    done
    local stem=$name
    while [[ $stem =~ \.[0-9]+$ ]]; do stem=${stem%.*}; done
    [[ $stem != "$name" ]] || return 1
    for id in ${abi_ids[@]+"${abi_ids[@]}"}; do
        [[ $id == "$stem" ]] && return 0
    done
    return 1
}

# report_owned_providers — name the gsa-managed package behind a missing
# soname family. Call ABORT PATH ONLY: `missing_stems` is populated in the same
# block that counts a finding, so gating the call on `findings` keeps a clean
# transaction from opening the index at all — that is what keeps a
# PreTransaction gate affordable, and the fixture pins it with a FIFO (an
# unconditional read blocks). Names only — no version, no command, no
# per-finding line: the fatal line is the finding and this says whose tree
# package is behind it.
#
# The index is line-delimited JSON (recipe_id, pkgnames, version, provides), so
# a row owns a stem when its provides array spells `<stem>=`; the soname stems
# are matched, never the versioned names, because a provider declares
# `libfoo.so` and makepkg versions it from the shipped ELF.
binpkg_index=${GSA_ABI_NEED_CHECK_BINPKG:-${GSA_STATE_DIR:-/var/lib/gsa}/index/binpkg.jsonl}
report_owned_providers() {
    [[ -r $binpkg_index ]] || return 0
    local stem stems='' owned
    for stem in "${!missing_stems[@]}"; do
        stems+="${stems:+ }$stem"
    done
    owned=$(awk -v stems="$stems" '
        BEGIN { n = split(stems, S, " ") }
        {
            for (i = 1; i <= n; i++) {
                if (index($0, "\"" S[i] "=") == 0) continue
                if (match($0, /"recipe_id":"[^"]*"/)) {
                    print substr($0, RSTART + 13, RLENGTH - 14)
                }
                break
            }
        }' "$binpkg_index" 2>/dev/null | sort -u | head -8)
    [[ -n $owned ]] || return 0
    printf 'abi-need-check: gsa-owned provider behind: %s\n' \
        "$(printf '%s\n' "$owned" | paste -sd' ' -)"
}

findings=0
idx=0
declare -A missing_stems=()
declare -a clean_lines=()
load_abi_exclusions

for root in "${roots[@]}"; do
    pkg=${pkgnames[$idx]}
    blob=${factblobs[$idx]}
    idx=$((idx + 1))
    pkg_findings=0
    pkg_needed=0

    # A registered package id is exempt wholesale (the registry's own first
    # field shape: "its outputs are exempt from the closure/provide checks").
    # Soname-level rows are honoured per miss below.
    if abi_excluded "$pkg"; then
        ((quiet)) ||
            printf 'abi-need-check: %s: skipped (documented ABI exclusion)\n' "$pkg"
        continue
    fi

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
                        if host_resolves "$needed" "$libdirs" "$elf_dir" "$class"; then
                            covered=1
                        fi
                        break
                    fi
                done
            fi
            if ((covered == 0)) && host_resolves "$needed" "$libdirs" "$elf_dir" "$class"; then
                covered=1
            fi

            if ((covered == 0)) && abi_excluded "$needed"; then
                # A registered soname/skid stem is a REVIEWED gap: the rot is
                # documented and owned, so it is not this gate's abort.
                continue
            fi
            if ((covered == 0)); then
                printf "abi-need-check: %s: '%s' needs '%s' — no file resolves it (fatal)\n" \
                    "$pkg" "${relpath##*/}" "$needed"
                pkg_findings=$((pkg_findings + 1))
                # Attribution input for the summary: the family stem, never
                # the versioned name — and never the directory part of a
                # path-style name, which no provide entry spells.
                stem=${needed##*/}
                while [[ $stem =~ \.[0-9]+$ ]]; do stem=${stem%.*}; done
                missing_stems[$stem]=1
            fi
        done
    done <<<"$blob"

    findings=$((findings + pkg_findings))
    # Deferred: phase 3 may still find that this transaction strands an
    # installed consumer, and a "clean" line above that verdict reads as a
    # contradiction. A run with any finding prints findings only.
    ((quiet)) || [[ $pkg_findings -gt 0 ]] || clean_lines+=("$pkg|$pkg_needed")
done

# ── Phase 3: the sonames this transaction TAKES AWAY (issue #7) ──────────
# Phase 2 resolves the INCOMING packages' DT_NEEDED. It is blind to the
# other direction: a provider moving `libsndio.so.7 -> .so.9` is
# transaction-internal consistent while every installed consumer of the OLD
# soname loses its file at the same instant. Measured 2026-11-20: a stock
# `pacman -Syu` passed this hook and left `mpv`, `celluloid` and
# `kodi.bin` dead on `libsndio.so.7`.
#
# So: diff each incoming package's shipped sonames against the sonames the
# INSTALLED package ships (the pacman local DB's `files` list is the
# package's file truth), keep the ones the transaction neither ships nor
# leaves a non-transaction file behind for, then resolve installed
# consumers of those names and refuse with `need-rebuild` rows. Coverage is
# transaction membership — a consumer whose own package is in `pkgnames` is
# satisfied, exactly the engine's `in_tx`.
#
# Two narrowings keep the rows honest, both class- and path-aware:
# a ship covering a drop must carry the SAME ELF class (upgrading `sndio`
# beside `lib32-sndio` still strands every 64-bit consumer), and a consumer
# that resolves the name through its own RUNPATH (a bundled `$ORIGIN/../lib`
# copy under /opt) is not a consumer of what disappears — the loader never
# consults the provider's directory for it.
#
# Cost (measured 2026-11-20, 24-core host): 22.8k candidates in 3.5 s of
# `find` plus ~1 s of parallel batched readelf, and the scan runs only when
# a soname is actually dropped. There is deliberately NO index: the
# engine's exhaustive `-Qr` report over every installed file takes 85 s,
# while this narrowed scan is cheaper than a cache would be to maintain —
# and a cache cannot go stale. Two narrowings, both stated rather than
# hidden: the loader's mapped SHAPES (executables by mode, shared objects by
# name), and the ELF ROOTS the loader maps them from — `usr/{bin,sbin,lib*,
# libexec}` plus `/opt` and `/usr/local` (an out-of-tree stock app such as
# Chrome or Spotify installs under `/opt` and links exactly like a packaged
# one).
abi_localdb=${GSA_ABI_NEED_CHECK_LOCALDB:-/var/lib/pacman}
# A fixture (or a `--sysroot`-shaped check) points this at a synthetic tree:
# every installed path the phase reads is prefixed with it.
abi_root=${GSA_ABI_NEED_CHECK_ROOT:-}

# post_resolves NAME CLASS — does a file still resolve NAME after this
# transaction? The installed DB answers for the very file the transaction
# replaces, so paths this transaction owns never count (that is the whole
# bug: `libsndio.so.7` resolves today and vanishes with the upgrade).
post_resolves() {
    local soname=$1 class=${2:-ELF64} dir path entries entry tag
    local -a dirs
    case $class in
        ELF32) dirs=("$abi_root"/usr/lib32 "$abi_root"/lib32) ;;
        *) dirs=("$abi_root"/usr/lib "$abi_root"/usr/lib64 "$abi_root"/lib "$abi_root"/lib64) ;;
    esac
    for dir in "${dirs[@]}"; do
        path=${dir%/}/$soname
        if [[ -e $path && -z ${owned_abs[$path]:-} ]]; then
            return 0
        fi
    done
    load_ld_cache
    entries=${ld_cache_by_name[$soname]:-}
    while [[ -n $entries ]]; do
        if [[ $entries == *';'* ]]; then
            entry=${entries%%;*}
            entries=${entries#*;}
        else
            entry=$entries
            entries=''
        fi
        tag=${entry%%|*}
        path=${abi_root}${entry#*|}
        case $class in
            ELF64) [[ $tag == *x86-64* ]] || continue ;;
            ELF32) [[ $tag != *x86-64* ]] || continue ;;
        esac
        if [[ -e $path && -z ${owned_abs[$path]:-} ]]; then
            return 0
        fi
    done
    return 1
}

# consumer_resolves FILE RUNPATH SONAME — does the CONSUMER itself still find
# SONAME after this transaction? A bundled private copy (`$ORIGIN/../lib/…`
# under /opt, the browser shape) is resolution the loader performs for that
# consumer alone: the provider's directory was never consulted, so dropping
# the provider's file strands nothing. Only RUNPATH-derived directories are
# asked — the default paths were already answered by `post_resolves` when the
# drop was recorded, and a relative entry is CWD-relative at run time (the
# hook cannot see the CWD, and claiming coverage it cannot see is the failure
# this gate exists to prevent).
consumer_resolves() {
    local file=$1 runpath=${2:-} soname=$3
    local origin=${file%/*} dir path
    [[ -n $runpath ]] || return 1
    local -a dirs=()
    local IFS=:
    for dir in $runpath; do
        case $dir in
            '$ORIGIN' | '${ORIGIN}') dirs+=("$origin") ;;
            '$ORIGIN/'*) dirs+=("$origin/${dir#'$ORIGIN/'}") ;;
            '${ORIGIN}/'*) dirs+=("$origin/${dir#'${ORIGIN}/'}") ;;
            /*) dirs+=("$dir") ;;
        esac
    done
    for dir in "${dirs[@]}"; do
        path=${dir%/}/$soname
        if [[ -e $path && -z ${owned_abs[$path]:-} ]]; then
            return 0
        fi
    done
    return 1
}

# db_pkg_dir NAME — the local-DB entry directory of the installed NAME. The
# glob also matches `foo-bar-1.0-1` for `foo`, so `%NAME%` is the authority.
db_pkg_dir() {
    local name=$1 dir found=''
    for dir in "$abi_localdb/local/$name"-*/; do
        [[ -d $dir ]] || continue
        if [[ $(sed -n '/^%NAME%$/{n;p;q;}' "$dir/desc" 2>/dev/null) == "$name" ]]; then
            found=$dir
        fi
    done
    [[ -n $found ]] && printf '%s' "$found"
}

# installed_sonames DIR — one `class<US>soname` row per DSO the INSTALLED
# package ships (its own `files` list, restricted to the ELF homes the
# engine probes: `elf_home` in gsa-abi's rows).
installed_sonames() {
    local dir=$1 rel path
    local -a batch=()
    while IFS= read -r rel; do
        [[ -n $rel && $rel != */ ]] || continue
        case $rel in
            usr/lib* | usr/libexec* | usr/bin* | usr/sbin* | *.so*) ;;
            *) continue ;;
        esac
        path=$abi_root/$rel
        [[ -f $path ]] && batch+=("$path")
    done < <(sed '1{/^%FILES%$/d;}' "$dir/files" 2>/dev/null)
    ((${#batch[@]})) || return 0
    readelf -hW -dW "${batch[@]}" 2>/dev/null | awk -v sUS="$US" '
        function emit() {
            if (son != "" && cls != "") printf "file%s%s%s%s\n", sUS, cls, sUS, son
            son = ""; cls = ""
        }
        /^File: / { emit(); next }
        /Class: *ELF64/ { cls = "ELF64"; next }
        /Class: *ELF32/ { cls = "ELF32"; next }
        /\(SONAME\)/ {
            if (match($0, /\[[^]]*\]/)) son = substr($0, RSTART + 1, RLENGTH - 2)
            next
        }
        END { emit() }
    '
}

if ((from_names && !file_install)) && ((${#pkgnames[@]})); then
    declare -A dropped_class=()   # "soname|class" -> the dropping package
    declare -A owned_abs=()       # absolute installed paths this transaction replaces
    declare -a drop_errors=()

    for pkg in "${pkgnames[@]}"; do
        entry=$(db_pkg_dir "$pkg")
        # Nothing installed: a fresh install can only ADD sonames.
        [[ -n $entry ]] || continue
        if [[ ! -r $entry/files ]]; then
            # Rule 71 at transaction time: a package whose installed file
            # truth cannot be read is not a package that drops nothing.
            drop_errors+=("$pkg")
            continue
        fi
        while IFS= read -r rel; do
            [[ -n $rel ]] && owned_abs["$abi_root/$rel"]=1
        done < <(sed '1{/^%FILES%$/d;}' "$entry/files" 2>/dev/null)
        while IFS=$'\x1f' read -r tag class son; do
            [[ $tag == file && -n $class && -n $son ]] || continue
            key="$son|$class"
            [[ -n ${dropped_class[$key]:-} ]] && continue
            # SHIPPED sonames only. A declared provide has its version
            # stripped at parse time (`libsndio.so=9-64` -> `libsndio.so`), and
            # a stem match against it would class the OLD generation as
            # covered — the exact false negative this phase exists to stop
            # (blind review 2026-11-20). A provide with no file behind it is
            # not coverage anywhere else in this gate either.
            # Class-scoped: a 64-bit drop is covered only by a 64-bit ship of
            # the same name. A transaction that upgrades `sndio` and
            # `lib32-sndio` together ships `libsndio.so.7` for the 32-bit
            # class only, and the 64-bit consumers are exactly who die.
            covered=0
            if [[ -n ${tx_shipped_class["$son|$class"]:-} || -n ${tx_ships_any[$son]:-} ]]; then
                covered=1
            fi
            ((covered)) && continue
            post_resolves "$son" "$class" && continue
            dropped_class[$key]=$pkg
        done < <(installed_sonames "$entry")
    done

    for pkg in ${drop_errors[@]+"${drop_errors[@]}"}; do
        printf 'abi-need-check: %s: installed file list is unreadable (%s/local/%s-*/files)\n' \
            "$pkg" "$abi_localdb" "$pkg"
        findings=$((findings + 1))
    done

    if ((${#dropped_class[@]})); then
        declare -a cand=()
        while IFS= read -r -d '' path; do
            cand+=("$path")
        done < <(find "$abi_root"/usr/bin "$abi_root"/usr/sbin "$abi_root"/usr/lib \
            "$abi_root"/usr/lib32 "$abi_root"/usr/lib64 "$abi_root"/usr/libexec \
            "$abi_root"/opt "$abi_root"/usr/local \
            -type f \( -perm -u+x -o -name '*.so*' \) -print0 2>/dev/null)

        # Per-chunk output files, then one read: parallel readelf writes
        # interleave, and a records stream cannot afford that.
        declare -A needing=()   # "soname|class" -> consumer names
        declare -A seen=()      # "soname|class|consumer" dedupe
        if ((${#cand[@]})); then
            chunk_dir="$scratch/installed-chunks.$$"
            mkdir -p "$chunk_dir"
            # readelf prints NO `File:` marker for a single input file, so a
            # chunk that happens to carry exactly one candidate would emit an
            # un-parseable record and lose its consumer (a silent false
            # negative in a fail-closed gate). The chunker knows the count, so
            # it writes the marker the multi-file form would have written.
            printf '%s\0' "${cand[@]}" |
                CHUNK_DIR=$chunk_dir xargs -0 -n 400 \
                    -P "$(nproc 2>/dev/null || echo 4)" \
                    sh -c 'f=$(mktemp "$CHUNK_DIR/chunk.XXXXXX") || exit 0
                           if [ "$#" -eq 1 ]; then printf "File: %s\n" "$1" >"$f"; fi
                           readelf -hW -dW "$@" >>"$f" 2>/dev/null' _
            for chunk in "$chunk_dir"/chunk.*; do
                [[ -f $chunk ]] || continue
                cat "$chunk"
            done | awk -v sUS="$US" -v sRS="$RS" '
                function emit() {
                    if (nd != "" && cls != "" && cur != "")
                        printf "file%s%s%s%s%s%s%s%s\n", sUS, cls, sUS, cur, sUS, rp, sUS, nd
                    nd = ""; cls = ""; cur = ""; rp = ""
                }
                /^File: / { emit(); cur = substr($0, 7); next }
                /Class: *ELF64/ { cls = "ELF64"; next }
                /Class: *ELF32/ { cls = "ELF32"; next }
                /\((RUNPATH|RPATH)\)/ {
                    if (match($0, /\[[^]]*\]/)) rp = substr($0, RSTART + 1, RLENGTH - 2)
                    next
                }
                /\(NEEDED\)/ {
                    if (match($0, /\[[^]]*\]/)) {
                        v = substr($0, RSTART + 1, RLENGTH - 2)
                        nd = (nd == "" ? v : nd sRS v)
                    }
                }
                END { emit() }
            ' >"$scratch/installed-needed.$$"
            rm -rf -- "$chunk_dir"

            while IFS=$'\x1f' read -r tag class path runpath needed_blob; do
                [[ $tag == file ]] || continue
                nb=$needed_blob
                while [[ -n $nb ]]; do
                    if [[ $nb == *"$RS"* ]]; then
                        needed=${nb%%"$RS"*}
                        nb=${nb#*"$RS"}
                    else
                        needed=$nb
                        nb=''
                    fi
                    key="$needed|$class"
                    [[ -n ${dropped_class[$key]:-} ]] || continue
                    # A consumer that carries its own copy along a RUNPATH is
                    # not a consumer of what disappears.
                    consumer_resolves "$path" "$runpath" "$needed" && continue
                    # The consumer's own package is the local DB's answer;
                    # a file no package owns is named by its path, because
                    # it has no transaction cover either.
                    owner=$(pacman -Qoq "$path" 2>/dev/null) || owner=''
                    if [[ -z $owner ]]; then
                        owner=$path
                    else
                        covered=0
                        for name in "${pkgnames[@]}"; do
                            [[ $owner == "$name" ]] && { covered=1; break; }
                        done
                        ((covered)) && continue
                        abi_excluded "$owner" && continue
                    fi
                    abi_excluded "$needed" && continue
                    pair="$key|$owner"
                    [[ -n ${seen[$pair]:-} ]] && continue
                    seen[$pair]=1
                    needing[$key]+="${needing[$key]:+ }$owner"
                done
            done <"$scratch/installed-needed.$$"
            rm -f -- "$scratch/installed-needed.$$"
        fi

        for key in "${!dropped_class[@]}"; do
            soname=${key%%|*}
            src=${dropped_class[$key]}
            consumers=${needing[$key]:-}
            [[ -n $consumers ]] || continue
            # Deterministic rows: the scan is parallel, so its order is not.
            consumers=$(printf '%s\n' $consumers | LC_ALL=C sort | paste -sd' ' -)
            printf 'abi-need-check: %s: drops %s (installed consumers: %s)\n' \
                "$src" "$soname" "${consumers// /, }"
            for owner in $consumers; do
                printf 'abi-need-check: need-rebuild %s %s\n' "$owner" "$soname"
                findings=$((findings + 1))
                stem=${soname##*/}
                while [[ $stem =~ \.[0-9]+$ ]]; do stem=${stem%.*}; done
                missing_stems[$stem]=1
            done
        done
    fi
fi

if ((findings)); then
    report_owned_providers
    exit 1
fi
for line in ${clean_lines[@]+"${clean_lines[@]}"}; do
    printf 'abi-need-check: %s: clean (%d runtime link(s))\n' "${line%%|*}" "${line#*|}"
done
exit 0
