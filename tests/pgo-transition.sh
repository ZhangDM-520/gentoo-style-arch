#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# One fixture covers every PGO-transition recipe. With no arguments it runs
# each package/project/recipe/style row in turn — the five six-line
# *-pgo-transition.sh wrappers this replaces did exactly that via `exec` — and
# with the positional arguments it runs only that pair. A failing pair
# fails the whole fixture. The fourth argument names the build-system family
# (meson or autotools): the families stub different build front-ends and bake
# flags in different places, so the contract pins and the transition
# assertions branch on it. A direct three-argument invocation sniffs the
# family from the recipe, keeping the documented interface.
if (($# == 0)); then
    status=0
    while read -r pkg proj recipe style; do
        bash "${BASH_SOURCE[0]}" "$pkg" "$proj" "$recipe" "$style" || status=1
    done <<'PAIRS'
cairo-git cairo packages/core/cairo-git meson
glib2-git glib packages/core/glib2-git meson
gtk3-git gtk packages/core/gtk3-git meson
gtk4-git gtk packages/core/gtk4-git meson
xorg-xwayland-git xserver packages/git/xorg-xwayland-git meson
jq jq-1.8.2 packages/stable/jq autotools
file file-5.48 packages/stable/file autotools
rsync rsync-3.5.1 packages/stable/rsync autotools
PAIRS
    exit $status
fi

package_id="${1:-glib2-git}"
project_dir="${2:-glib}"
recipe_path="${3:-packages/core/glib2-git}"
style="${4:-}"
if test -z "$style"; then
    if grep -q '^[[:space:]]*[.]/configure' "$root/$recipe_path/PKGBUILD"; then
        style=autotools
    else
        style=meson
    fi
fi
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-pgo-${package_id}.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

mkdir -p "$fixture/bin" "$fixture/$project_dir"

cat >"$fixture/bin/arch-meson" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

test "${2:-}" = build
mkdir -p build
{
    printf 'c_args=%s\n' "${CFLAGS:-}"
    printf 'cpp_args=%s\n' "${CXXFLAGS:-}"
    # Meson carries compiler instrumentation into its cached link options.
    printf 'c_link_args=%s\n' "${CFLAGS:-}"
    printf 'cpp_link_args=%s\n' "${CXXFLAGS:-}"
} >build/fake-meson-cache
EOF
chmod +x "$fixture/bin/arch-meson"

cat >"$fixture/bin/meson" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

cache=build/fake-meson-cache

set_option() {
    local key="$1"
    local value="$2"
    local replacement
    replacement=$(mktemp)
    awk -F= -v key="$key" '$1 != key' "$cache" >"$replacement"
    printf '%s=%s\n' "$key" "$value" >>"$replacement"
    mv "$replacement" "$cache"
}

case "${1:-}" in
    compile)
        mkdir -p build/meson-private
        : >build/meson-private/sanity_check_for_c.exe
        chmod +x build/meson-private/sanity_check_for_c.exe
        grep -E '^c_args=' "$cache" >>build/compile.log
        exit 0
        ;;
    test)
        mkdir -p build
        for profile in $(seq 1 "${PGO_FIXTURE_GCDA_COUNT:-120}"); do
            : >"build/profile-$profile.gcda"
        done
        exit 0
        ;;
    configure)
        printf '%s\n' "$*" >>build/configure.log
        exit 0
        ;;
    setup)
        shift
        if test "${1:-}" = --reconfigure; then
            shift
            for argument in "$@"; do
                case "$argument" in
                    -Dc_args=*) set_option c_args "${argument#-Dc_args=}" ;;
                    -Dcpp_args=*) set_option cpp_args "${argument#-Dcpp_args=}" ;;
                    -Dc_link_args=*) set_option c_link_args "${argument#-Dc_link_args=}" ;;
                    -Dcpp_link_args=*) set_option cpp_link_args "${argument#-Dcpp_link_args=}" ;;
                esac
            done

            if grep -E '^(c_args|cpp_args|c_link_args|cpp_link_args)=' "$cache" |
                grep -F -- '-fprofile-generate' >/dev/null; then
                printf 'cached profile-generate flag survived final reconfigure\n' >&2
                exit 1
            fi
            if grep -Eq '^c_args=.*-fprofile-use=' "$cache"; then
                # Profile path: both languages carry the profile, with the
                # probe exemption that keeps feature detection honest.
                if ! grep -Eq '^cpp_args=.*-fprofile-use=' "$cache" ||
                    ! grep -Eq '^c_args=.*-Wno-error=missing-profile' "$cache" ||
                    ! grep -Eq '^cpp_args=.*-Wno-error=missing-profile' "$cache"; then
                    printf 'final reconfigure did not enable the full profile-use flag set\n' >&2
                    exit 1
                fi
                : >build/mode-profile
            else
                # Fallback path: a thin training run must land on a clean,
                # non-instrumented configuration — no generate flag may come
                # back, and no profile-use may appear either.
                if grep -E '^(c_args|cpp_args|c_link_args|cpp_link_args)=' "$cache" |
                    grep -Eq -- '-fprofile-(generate|use)'; then
                    printf 'fallback reconfigure left profile flags in the cache\n' >&2
                    exit 1
                fi
                : >build/mode-fallback
            fi
        fi
        exit 0
        ;;
    *)
        printf 'unexpected fake meson invocation: %s\n' "$*" >&2
        exit 2
        ;;
esac
EOF
chmod +x "$fixture/bin/meson"

cat >"$fixture/bin/readelf" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" == *meson-private/sanity_check_for_c.exe* ]]; then
    printf '0000000000000000 g    DF .text  0000000000000000 __gcov_init\n'
    exit 0
fi

if [[ "$*" == *instrumented-symbols/* ]]; then
    printf '0000000000000000 g    DF .text  0000000000000000 __gcov_init\n'
    exit 0
fi

exec /usr/bin/readelf "$@"
EOF
chmod +x "$fixture/bin/readelf"

# Autotools family stubs: `configure` bakes CFLAGS/LDFLAGS into a Makefile the
# way ./configure bakes them into the generated one, and `make` logs the flags
# each build pass compiled with. The training targets write one fake .gcda per
# touched TU into the recipe's profile directory so the floor guard has real
# counts to threshold on.
if test "$style" = autotools; then
    cat >"$fixture/bin/make" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

cache=build/fake-configure-cache
target=""
for argument in "$@"; do
    case "$argument" in
        -* | *=*) ;;
        *) target="$argument" ;;
    esac
done

case "$target" in
    check | test)
        mkdir -p pgo-profiles
        for profile in $(seq 1 "${PGO_FIXTURE_GCDA_COUNT:-120}"); do
            : >"pgo-profiles/profile-$profile.gcda"
        done
        ;;
    clean)
        # Real `make clean` drops objects but never the profiles (they live
        # outside the object tree) and must not truncate the compile log —
        # the fallback assertions need the phase-1 line.
        : ;;
    install) ;;
    *)
        mkdir -p build
        grep -E '^cflags=' "$cache" >>build/compile.log
        ;;
esac
EOF
    chmod +x "$fixture/bin/make"

    cat >"$fixture/$project_dir/configure" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

mkdir -p build
{
    printf 'cflags=%s\n' "${CFLAGS:-}"
    printf 'ldflags=%s\n' "${LDFLAGS:-}"
} >build/fake-configure-cache
printf 'cflags=%s ldflags=%s\n' "${CFLAGS:-}" "${LDFLAGS:-}" >>build/configure.log
printf 'CFLAGS = %s\nLDFLAGS = %s\n' "${CFLAGS:-}" "${LDFLAGS:-}" >Makefile
# file's build() re-applies the Arch libtool fixup to the generated libtool
# after every configure run — give that sed a `-shared` line to edit.
printf 'deplibs_check_method=pass_all link_mode=libtool deplibs=" -shared "\n' >libtool
exit 0
EOF
    chmod +x "$fixture/$project_dir/configure"
fi

cat >"$fixture/run-build.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$fixture"
export CARCH="${CARCH:-x86_64}"
warning() { :; }
msg() { :; }
error() {
    printf '%s\n' "$*" >&2
    return 1
}
# makepkg shim: $startdir is the recipe directory before the PKGBUILD is
# sourced — this is how the real builder resolves `source "$startdir/…"`.
startdir="$root/$recipe_path"
source "$root/$recipe_path/PKGBUILD"

# Contract pins for the C-autotools tier (static).
if test "$style" = autotools; then
    pkb="$root/$recipe_path/PKGBUILD"

    # CFLAGS bake at ./configure time, so every phase must re-run it:
    # instrument, the plain fallback and the profile-use reconfigure.
    configure_runs=$(grep -c '^[[:space:]]*[.]/configure' "$pkb" || true)
    test "$configure_runs" -ge 3 || {
        printf 'expected 3 ./configure phases, found %s\n' "$configure_runs" >&2
        exit 1
    }

    # instrument/train/use flags present — and the pair must name one shared
    # profile directory, or the use phase silently compiles without profiles.
    grep -q -- '-fprofile-generate=' "$pkb" || {
        printf 'no -fprofile-generate=<dir> instrumentation phase\n' >&2
        exit 1
    }
    grep -q -- '-fprofile-use=' "$pkb" || {
        printf 'no -fprofile-use=<dir> profile phase\n' >&2
        exit 1
    }

    # The generate and use targets must be the SAME directory: profiles are
    # looked up as <dir>/<mangled-object-path>.gcda, so a mismatched pair
    # compiles a profile-less build without failing the build.
    gen_target=$(grep -o -- '-fprofile-generate=[^ "]*' "$pkb" | head -n1)
    use_target=$(grep -o -- '-fprofile-use=[^ "]*' "$pkb" | head -n1)
    test "${gen_target#-fprofile-generate=}" = "${use_target#-fprofile-use=}" || {
        printf 'generate/use profile dirs differ: %s vs %s\n' \
            "$gen_target" "$use_target" >&2
        exit 1
    }
    grep -qE 'make (check|test)' "$pkb" || {
        printf 'no explicit training run\n' >&2
        exit 1
    }

    # Floor guard + plain-build fallback.
    grep -q 'pgo_min_gcda' "$pkb" || {
        printf 'no pgo_min_gcda floor guard\n' >&2
        exit 1
    }

    # Optimisation policy: the host makepkg.conf is the only source of
    # optimisation flags; the recipe must not add its own.
    if grep -nE -- '-(O3|march[= ]|mtune[= ])' "$pkb"; then
        printf 'recipe adds its own optimisation flags\n' >&2
        exit 1
    fi

    # The fatal gate must be the LAST statement of package().
    last_statement=$(awk '
        /^package\(\)/ { inside = 1; next }
        inside && /^[[:space:]]*}/ { exit }
        inside && $0 !~ /^[[:space:]]*#/ && NF { line = $0 }
        END { print line }
    ' "$pkb")
    grep -qE '^[[:space:]]*verify_no_profile_instrumentation[[:space:]]' <<<"$last_statement" || {
        printf 'fatal gate is not the last statement of package(): %s\n' "$last_statement" >&2
        exit 1
    }
fi

rm -rf "$fixture/build" "$fixture/pkg" "$fixture/$project_dir/build" "$fixture/$project_dir/pgo-profiles"
build

# build() ends in the recipe's source directory, so anchor below on $fixture.
# Meson stubs log under fixture/build; the autotools stubs log under the
# source tree the recipe configured in.
if test "$style" = autotools; then
    log_dir="$fixture/$project_dir/build"
else
    log_dir="$fixture/build"
fi

pkgdir="$fixture/pkg"
mkdir -p "$pkgdir/usr/lib"
# A clean payload may still *mention* a .gcda path in shipped text: the
# predicate matches a standalone absolute path, so prose must not fail it.
printf 'coverage notes: rebuild /tmp/x/src/A.dir/b.cxx.gcda\n' \
    >"$pkgdir/usr/lib/$package_id.so"
verify_no_profile_instrumentation "$pkgdir"

# Two shapes of leak, so both detectors stay load-bearing:
#  - symbols: what readelf finds, and only before makepkg strips
#  - paths:   what survives stripping, so only the path predicate sees it
mkdir -p "$fixture/instrumented-symbols" "$fixture/instrumented-paths"
: >"$fixture/instrumented-symbols/$package_id.so"
printf 'code\0/home/someone/build/pgo-fixture/%s/src/A.dir/b.cxx.gcda\0code\n' \
    "$package_id" >"$fixture/instrumented-paths/$package_id.so"

# The shared gate (lib/pgo.sh, sourced through the PKGBUILD) is fatal by
# design — it calls `exit 1` — so the negative cases run it in subshells and
# assert the subshell's exit status.
if ( verify_no_profile_instrumentation "$fixture/instrumented-symbols" ) 2>/dev/null; then
    printf 'instrumented package fixture unexpectedly passed (coverage symbols)\n' >&2
    exit 1
fi
if ( verify_no_profile_instrumentation "$fixture/instrumented-paths" ) 2>/dev/null; then
    printf 'instrumented package fixture unexpectedly passed (.gcda paths)\n' >&2
    exit 1
fi

# The transition itself: phase 1 compiles instrumented; the final compile
# must be the one the threshold branch selected.
first_compile=$(head -n1 "$log_dir/compile.log")
last_compile=$(tail -n1 "$log_dir/compile.log")
if test "$style" = autotools; then
    # Every phase re-runs ./configure: the instrument pass plus exactly one
    # of profile-use / plain fallback.
    configure_runs=$(wc -l <"$log_dir/configure.log")
    test "$configure_runs" -eq 2 || {
        printf 'expected 2 configure runs, saw %s\n' "$configure_runs" >&2
        exit 1
    }
    first_configure=$(head -n1 "$log_dir/configure.log")
    case "$first_configure" in
        *-fprofile-generate=*) ;;
        *)
            printf 'phase-1 configure was not instrumented: %s\n' "$first_configure" >&2
            exit 1
            ;;
    esac
    # Instrumentation drops -flto; the host flags come back in phase 2.
    case "$first_configure" in
        *-flto*)
            printf 'phase-1 instrumentation kept -flto: %s\n' "$first_configure" >&2
            exit 1
            ;;
    esac
    case "$first_compile" in
        *-fprofile-generate=*) ;;
        *)
            printf 'phase-1 compile was not instrumented: %s\n' "$first_compile" >&2
            exit 1
            ;;
    esac
fi
case "${PGO_FIXTURE_EXPECT:?}" in
    profile)
        if test "$style" = autotools; then
            final_configure=$(tail -n1 "$log_dir/configure.log")
            case "$final_configure" in
                *-fprofile-use=*) ;;
                *)
                    printf 'profile branch: final configure is not profile-use: %s\n' \
                        "$final_configure" >&2
                    exit 1
                    ;;
            esac
            case "$final_configure" in
                *-flto*) ;;
                *)
                    printf 'profile branch: host LTO flag was not restored: %s\n' \
                        "$final_configure" >&2
                    exit 1
                    ;;
            esac
        else
            test -f "$log_dir/mode-profile" || {
                printf 'profile branch: no profile-use reconfigure happened\n' >&2
                exit 1
            }
        fi
        case "$last_compile" in
            *-fprofile-use*) ;;
            *)
                printf 'profile branch: final compile is not profile-use: %s\n' \
                    "$last_compile" >&2
                exit 1
                ;;
        esac
        ;;
    fallback)
        if test "$style" = autotools; then
            final_configure=$(tail -n1 "$log_dir/configure.log")
            case "$final_configure" in
                *-fprofile-*)
                    printf 'fallback branch: final configure still carries profile flags: %s\n' \
                        "$final_configure" >&2
                    exit 1
                    ;;
            esac
            case "$final_configure" in
                *-flto*) ;;
                *)
                    printf 'fallback branch: LTO was not re-enabled on the final configure\n' >&2
                    exit 1
                    ;;
            esac
        else
            test -f "$log_dir/mode-fallback" || {
                printf 'fallback branch: no clean reconfigure happened\n' >&2
                exit 1
            }
        fi
        case "$first_compile" in
            *-fprofile-generate*) ;;
            *)
                printf 'fallback branch: phase-1 compile was not instrumented: %s\n' \
                    "$first_compile" >&2
                exit 1
                ;;
        esac
        # The below-threshold branch must compile a FINAL NON-INSTRUMENTED
        # build — the 2026-09-16 bug class half-reconfigured and compiled a
        # still-instrumented payload.
        case "$last_compile" in
            *-fprofile-*)
                printf 'fallback branch: final compile still carries profile flags: %s\n' \
                    "$last_compile" >&2
                exit 1
                ;;
        esac
        # ...and it re-enables LTO on the way out.
        if test "$style" = meson; then
            case "$(tail -n1 "$log_dir/configure.log")" in
                *b_lto=true*) ;;
                *)
                    printf 'fallback branch: LTO was not re-enabled on the final configure\n' >&2
                    exit 1
                    ;;
            esac
        fi
        ;;
    *)
        printf 'unexpected PGO_FIXTURE_EXPECT: %s\n' "$PGO_FIXTURE_EXPECT" >&2
        exit 1
        ;;
esac
EOF
chmod +x "$fixture/run-build.sh"

env \
    PATH="$fixture/bin:$PATH" \
    CFLAGS='-O3 -flto=auto' \
    CXXFLAGS='-O3 -flto=auto' \
    LDFLAGS='-flto=auto' \
    fixture="$fixture" \
    root="$root" \
    recipe_path="$recipe_path" \
    package_id="$package_id" \
    style="$style" \
    project_dir="$project_dir" \
    PGO_FIXTURE_GCDA_COUNT=120 \
    PGO_FIXTURE_EXPECT=profile \
    "$fixture/run-build.sh"

# The below-threshold branch is a real branch, not dead code: it is what a
# thin or failed training run falls back to, and it harboured the 2026-09-16
# bug class (a half-reconfigure that compiled a still-instrumented final
# build). Drive it with a stub training run that touches only 3 TUs — below
# every pair's threshold — and assert the fallback reconfigures cleanly,
# re-enables LTO and compiles a final non-instrumented build.
env \
    PATH="$fixture/bin:$PATH" \
    CFLAGS='-O3 -flto=auto' \
    CXXFLAGS='-O3 -flto=auto' \
    LDFLAGS='-flto=auto' \
    fixture="$fixture" \
    root="$root" \
    recipe_path="$recipe_path" \
    package_id="$package_id" \
    style="$style" \
    project_dir="$project_dir" \
    PGO_FIXTURE_GCDA_COUNT=3 \
    PGO_FIXTURE_EXPECT=fallback \
    "$fixture/run-build.sh"

printf 'PGO transition fixture (%s): PASS\n' "$package_id"
