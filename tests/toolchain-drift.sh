#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-toolchain-drift.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

dir="$fixture/workspace"
make_workspace "$dir" 1 2 low
add_package "$dir" p1 $'pkgver=1.0.0\npkgrel=1\narch=(any)'

cat >"$dir/bin/gcc" <<'EOF'
#!/usr/bin/env bash
set -u
[[ ${1:-} == --version ]] || exit 2
printf 'gcc (fixture) %s\n' "${GSA_FAKE_GCC_VERSION:?}"
EOF
chmod +x "$dir/bin/gcc"

cat >"$dir/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'run\n' >>"${GSA_FAKE_MAKEPKG_COUNT:?}"
mkdir -p "$PWD/src"
if [[ -e "$PWD/src/stale-lto.o" ]]; then
    printf 'stale LTO object survived the compiler-drift clean\n' >&2
    exit 92
fi
if [[ "${GSA_FAKE_FAIL_PACKAGE:-}" == "$(basename "$PWD")" ]]; then
    : >"$PWD/src/stale-lto.o"
    printf 'simulated makepkg failure after partial compilation\n' >&2
    exit 1
fi
: >"$PWD/src/fresh-lto.o"
: >"$PWD/p1-1.0.0-1-any.pkg.tar.zst"
EOF
chmod +x "$dir/bin/makepkg"

builder_args=(p1)
run_case() { # $1 = compiler version, rest = fixture environment overrides
    local version=$1
    shift
    run_builder env \
        PATH="$dir/bin:$PATH" \
        GSA_STATE_DIR="$dir/state" \
        GSA_FAKE_GCC_VERSION="$version" \
        GSA_FAKE_MAKEPKG_COUNT="$dir/makepkg.count" \
        GSA_CPU_THREADS=8 \
        GSA_MEMORY_GIB=16 \
        "$@" \
        fish "$dir/build-all.fish" \
        --allow-broken-rustc --no-deps --no-sync "${builder_args[@]}"
    return "$FIXTURE_RC"
}

makepkg_runs() {
    grep -c '^run$' "$dir/makepkg.count" 2>/dev/null || true
}

if ! run_case '17.0.0 20260906'; then
    printf 'initial build failed:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
: >"$dir/packages/p1/src/stale-lto.o"

# An unchanged identity can retain its completed tree and archive under -s.
builder_args=(-s p1)
if ! run_case '17.0.0 20260906'; then
    printf 'same-toolchain skip failed:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
if [[ $(makepkg_runs) != 1 || ! -e "$dir/packages/p1/src/stale-lto.o" ]]; then
    printf 'same-toolchain run did not skip while preserving its build tree:\n%s\n' \
        "$FIXTURE_OUTPUT" >&2
    exit 1
fi

# Drift must override -s and clean before makepkg. Simulate a failed compile:
# the new identity must NOT be committed, so the retry cleans again.
if run_case '17.0.0 20260920' GSA_FAKE_FAIL_PACKAGE=p1; then
    printf 'compiler drift was ignored by --skip:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
if grep -q 'stale LTO object survived' <<<"$FIXTURE_OUTPUT"; then
    printf 'compiler drift did not clean stale objects before rebuilding:\n%s\n' \
        "$FIXTURE_OUTPUT" >&2
    exit 1
fi
if ! grep -q 'simulated makepkg failure after partial compilation' <<<"$FIXTURE_OUTPUT"; then
    printf 'the drift build did not reach the simulated compiler failure:\n%s\n' \
        "$FIXTURE_OUTPUT" >&2
    exit 1
fi

if ! run_case '17.0.0 20260920'; then
    printf 'retry after the failed drift build did not clean and rebuild:\n%s\n' \
        "$FIXTURE_OUTPUT" >&2
    exit 1
fi
if [[ $(makepkg_runs) != 3 ]]; then
    printf 'expected initial, failed-drift, and successful retry builds; saw %s:\n%s\n' \
        "$(makepkg_runs)" "$FIXTURE_OUTPUT" >&2
    exit 1
fi

if ! run_case '17.0.0 20260920'; then
    printf 'same-toolchain post-rebuild skip failed:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi
if [[ $(makepkg_runs) != 3 ]]; then
    printf 'unchanged compiler identity did not skip the completed rebuild:\n%s\n' \
        "$FIXTURE_OUTPUT" >&2
    exit 1
fi

printf 'toolchain drift fixture: PASS\n'
