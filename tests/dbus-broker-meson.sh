#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
recipe=$root/packages/git/dbus-broker-git
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-dbus-broker-meson.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    printf 'dbus-broker Meson fixture: %s\n' "$1" >&2
    exit 1
}

srcdir=$tmp/src
stale_option=$srcdir/build/meson-private/missing-b-freestanding
meson_log=$tmp/meson.log
mkdir -p "$tmp/bin" "$srcdir/dbus-broker-git" "$(dirname "$stale_option")"
: >"$stale_option"

cat >"$tmp/bin/meson" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

args=("$@")
printf '%s' "${args[0]}" >>"$GSA_FAKE_MESON_LOG"
printf ' <%s>' "${args[@]:1}" >>"$GSA_FAKE_MESON_LOG"
printf '\n' >>"$GSA_FAKE_MESON_LOG"

case ${args[0]} in
    setup)
        for arg in "${args[@]}"; do
            if [[ $arg == --wipe ]]; then
                rm -f -- "${GSA_FAKE_MESON_STALE_OPTION:?}"
            fi
        done
        ;;
    compile)
        if [[ -e ${GSA_FAKE_MESON_STALE_OPTION:?} ]]; then
            printf "KeyError: 'Tried to access nonexistant project parent option b_freestanding.'\n" >&2
            exit 1
        fi
        ;;
    *)
        printf 'unexpected meson invocation: %s\n' "$*" >&2
        exit 2
        ;;
esac
EOF
chmod +x "$tmp/bin/meson"

if ! (
    cd "$srcdir"
    export PATH="$tmp/bin:$PATH"
    export LDFLAGS=
    export GSA_FAKE_MESON_LOG=$meson_log
    export GSA_FAKE_MESON_STALE_OPTION=$stale_option
    source "$recipe/PKGBUILD"
    build
) >"$tmp/build.log" 2>&1; then
    cat "$tmp/build.log"
    fail 'build reused stale Meson compiler options instead of wiping its build directory'
fi

[[ $(grep -c '^setup ' "$meson_log") -eq 1 ]] ||
    fail 'expected one Meson setup call'
[[ $(grep -c '^compile ' "$meson_log") -eq 1 ]] ||
    fail 'expected one Meson compile call'
grep -Fq '<--wipe>' "$meson_log" ||
    fail 'Meson setup must wipe cached options before compiling'
[[ ! -e $stale_option ]] ||
    fail 'Meson setup left the stale b_freestanding state in place'

printf 'dbus-broker Meson fixture: PASS (stale compiler-option state is wiped)\n'
