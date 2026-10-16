#!/usr/bin/env bash
set -euo pipefail

# bpftune dlopens the tuner plugins in /usr/lib/bpftune/ and keeps pointers into
# those mappings, so replacing the files underneath the running process kills a
# worker thread inside strstr() with SIGSEGV/SEGV_MAPERR.  That is measured:
# /var/lib/systemd/coredump holds exactly two bpftune cores, they are the same
# fault at the same offset, and each is stamped in the same second as the
# `pacman -U` of bpftune-git that rewrote the plugins --
#
#   2026-09-16 07:38:35  reinstall, crash in the same second
#   2026-09-16 18:57:50  reinstall, crash in the same second
#
# -- so the recipe has to stop the unit before the swap and start it after, and
# has to ship both halves.  This fixture asserts the assets, the packaging, the
# checksums, and the decisions the script actually makes against a stubbed
# systemctl.
#
# Red-verified: dropping either hook, mismatching the checksums, or inverting
# the marker logic each makes it fail.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
recipe="packages/git/bpftune-git"
script="$recipe/bpftune-restart.script"
pre_hook="$recipe/50-bpftune-tuners-pre.hook"
post_hook="$recipe/95-bpftune-tuners-post.hook"

fail() {
    printf 'bpftune tuner-swap fixture: %s\n' "$1" >&2
    exit 1
}

# --- the assets exist, are committed, and parse ------------------------------
for asset in "$script" "$pre_hook" "$post_hook"; do
    [[ -f $root/$asset ]] || fail "missing recipe asset: $asset"
    git -C "$root" ls-files --error-unmatch -- "$asset" >/dev/null 2>&1 ||
        fail "untracked recipe asset: $asset"
done

sh -n "$root/$script" || fail 'bpftune-restart.script does not parse'

# --- every local source is listed with a checksum that matches ---------------
mapfile -t sources < <(cd "$root/$recipe" &&
    bash -c 'source ./PKGBUILD >/dev/null 2>&1; printf "%s\n" "${source[@]}"')
mapfile -t sums < <(cd "$root/$recipe" &&
    bash -c 'source ./PKGBUILD >/dev/null 2>&1; printf "%s\n" "${md5sums[@]}"')

# A source added without its checksum is the silent half of this change: makepkg
# refuses to build, but only when someone runs it.
[[ ${#sources[@]} -eq ${#sums[@]} ]] ||
    fail "${#sources[@]} source entries but ${#sums[@]} checksums"

for i in "${!sources[@]}"; do
    case "${sources[$i]}" in
        *://* | *::*) continue ;;
    esac
    asset=${sources[$i]}
    [[ $asset == "${pre_hook##*/}" || $asset == "${post_hook##*/}" ||
        $asset == "${script##*/}" ]] ||
        fail "unexpected local source: $asset"
    have=$(md5sum "$root/$recipe/$asset" | cut -d' ' -f1)
    [[ ${sums[$i]} == "$have" ]] ||
        fail "checksum for $asset is ${sums[$i]}, file is $have"
done

# --- the recipe installs both hooks and the script they call ----------------
pkgbuild="$root/$recipe/PKGBUILD"
for installed in \
    usr/share/libalpm/hooks/50-bpftune-tuners-pre.hook \
    usr/share/libalpm/hooks/95-bpftune-tuners-post.hook \
    usr/share/libalpm/scripts/bpftune-restart; do
    grep -qF "\$pkgdir/$installed" "$pkgbuild" ||
        fail "PKGBUILD does not install $installed"
done

# --- the two halves are the two different phases -----------------------------
for hook in "$root/$pre_hook" "$root/$post_hook"; do
    [[ -f $hook ]] || continue
    grep -qx 'Type = Package' "$hook" || fail "$hook is not a package trigger"
    grep -qx 'Target = bpftune-git' "$hook" ||
        fail "$hook does not trigger on bpftune-git"
    # A fresh install rewrites the plugins exactly as an upgrade does.
    grep -qx 'Operation = Install' "$hook" || fail "$hook skips Install"
    grep -qx 'Operation = Upgrade' "$hook" || fail "$hook skips Upgrade"
done

grep -qx 'When = PreTransaction' "$root/$pre_hook" ||
    fail 'the stop half is not a PreTransaction action'
grep -qx 'When = PostTransaction' "$root/$post_hook" ||
    fail 'the start half is not a PostTransaction action'
grep -qx 'Exec = /usr/share/libalpm/scripts/bpftune-restart pre' "$root/$pre_hook" ||
    fail 'the pre hook does not run the script pre half'
grep -qx 'Exec = /usr/share/libalpm/scripts/bpftune-restart post' "$root/$post_hook" ||
    fail 'the post hook does not run the script post half'

# --- .SRCINFO must match the recipe ------------------------------------------
# .SRCINFO freshness (the check that catches a checksum edited in the PKGBUILD
# after .SRCINFO was generated) is owned by tests/srcinfo-freshness.sh, which
# covers every recipe from the --topology channel — not re-asserted here.

# --- what the script decides, against a stubbed systemctl -------------------
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat >"$work/bin/systemctl" <<'STUB'
#!/bin/sh
# Fail closed: an unmodeled verb or a missing argument is a refusal (exit 2),
# never a silent success. The modeled verbs keep propagating their own
# status (is-active/is-failed answer the stub state with the test's rc).
if [ $# -lt 1 ]; then
    echo "systemctl: missing verb" >&2
    exit 2
fi
verb=$1
shift
while [ $# -gt 0 ]; do
    case $1 in
        --*) shift ;;
        *) break ;;
    esac
done
case $verb in
    is-active) [ "$(cat "$STUB_STATE")" = active ] ;;
    is-failed) [ "$(cat "$STUB_STATE")" = failed ] ;;
    stop | start | try-restart)
        if [ $# -lt 1 ]; then
            echo "systemctl: missing unit for $verb" >&2
            exit 2
        fi
        printf '%s %s\n' "$verb" "$1" >>"$STUB_LOG"
        ;;
    *) echo "systemctl: unknown verb '$verb'" >&2; exit 2 ;;
esac
STUB
chmod 755 "$work/bin/systemctl"

# run <state> <phase> -> prints the systemctl verbs the script used
run() {
    : >"$work/log"
    printf '%s' "$1" >"$work/state"
    if PATH="$work/bin:$PATH" BPFTUNE_SWAP_MARKER="$work/marker" \
        STUB_STATE="$work/state" STUB_LOG="$work/log" \
        sh "$root/$script" "$2" >/dev/null 2>&1; then :; else
        fail "the script failed on '$2' with the unit $1"
    fi
    cat "$work/log"
}

expect() {
    [[ $1 == "$2" ]] || fail "$3: expected [$2], got [$1]"
}

# Running: stopped for the swap, and owed a start afterwards.
expect "$(run active pre)" 'stop bpftune.service' 'a running unit is not stopped'
[[ -e $work/marker ]] || fail 'the pre half did not record that it stopped the unit'
expect "$(run active post)" 'start bpftune.service' 'the recorded unit is not started again'
if [[ -e $work/marker ]]; then
    fail 'the post half left the marker behind'
fi

# Failed -- start-limit-hit after an earlier swap -- is the same case: this
# install is the next chance to bring it back, so it must not be skipped.
expect "$(run failed pre)" 'stop bpftune.service' 'a failed unit is not reset'

# Stopped by the user: the pre half must not stop it, and the post half must
# not start it -- it may only repair a unit that is running.
: >"$work/log"
printf 'inactive' >"$work/state"
rm -f "$work/marker"
out=$(run inactive pre)
expect "$out" '' 'stopping a stopped unit'
if [[ -e $work/marker ]]; then
    fail 'the pre half recorded a unit it never stopped'
fi
out=$(run inactive post)
expect "$out" 'try-restart bpftune.service' \
    'a unit whose pre half did not run is not repaired with restart-if-running'

# A bad invocation is an error, not a silent no-op.
if PATH="$work/bin:$PATH" sh "$root/$script" >/dev/null 2>&1; then
    fail 'the script accepted a missing phase'
fi
if PATH="$work/bin:$PATH" sh "$root/$script" sideways >/dev/null 2>&1; then
    fail 'the script accepted an unknown phase'
fi

printf 'bpftune tuner-swap fixture: PASS\n'
