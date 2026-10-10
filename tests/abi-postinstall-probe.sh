#!/usr/bin/env bash
set -euo pipefail

# ABI-drift guard layer 4 — the post-install NEEDED probe
# (build-all.fish install_needed_probe, run by install_execute after every
# successful transaction — the -i lane and -ia share that one executor). A
# stub "fabricates install results": pacman -U records the transaction and
# the fake installed database (pacman -Qi full dump) grows from it, so the
# probe resolves against exactly the NEWLY INSTALLED + EXISTING provide set
# the real one would see. Pinned:
#
#   A. clean: a consumer output whose DT_NEEDED libgreet.so.1 resolves via
#      the EXISTING set (a pre-installed package's auto-versioned provide
#      'libgreet.so=1-64' covers soname libgreet.so.1) → run succeeds, no
#      probe output;
#   B. failure: nothing provides the needed soname → the transaction lands,
#      then the run ABORTS loudly naming the member and the unresolved
#      sonames, rc != 0, no success reported;
#   C. the NEWLY INSTALLED half of the resolution set: provider + consumer in
#      one transaction (the -ia collective install), the existing set empty —
#      the provider's own .PKGINFO provide covers the consumer's NEEDED;
#   D. the exclusions registry resolves source (c) for the probe too;
#   G. the runtime-file half of resolution (2026-10-06 full build): a NEEDED
#      whose file is OWNED by an installed package resolves even when no
#      package declares the soname provide — stock Arch ships libx11/libxt/
#      libxext without `provides=(libX11.so)`, so the provide set alone
#      false-aborts every consumer of a provider that never declared one.
#      The ownership list is `pacman -Ql`'s, fabricated by the stub;
#   H. the same for a file SHIPPED by the transaction itself (a private lib
#      in the same batch, no provide declared): shipped bytes resolve too.
#   I. path-style NEEDED names (a SONAME-less DSO linked by absolute path —
#      run #119's mujs/mpv class) resolve via their EXACT owned path;
#   J. …and only via the exact path: a same-basename file owned elsewhere
#      does not satisfy the loader, so an unowned path stays fail-closed.
#
# Everything under $TMPDIR; ELF payloads synthesized with cc (like
# tests/provides-audit.sh); the real /usr and the real pacman DB are never
# touched (pacman/pacman-conf/sudo all stubbed).

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/tests/lib/fixture-lib.bash"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-abi-postinstall-probe.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    printf 'abi-postinstall-probe fixture: %s\n' "$1" >&2
    exit 1
}

command -v cc >/dev/null 2>&1 || fail 'cc is required to synthesize ELF payloads'
command -v readelf >/dev/null 2>&1 || fail 'readelf is required'

checks=0

ws="$tmp/ws"
make_workspace "$ws" 1 2 low
make_install_conf "$ws/pacman.conf" # this run's IgnorePkg registration target (never the host's)
add_package "$ws" libs-git "$gsa_meta_any"
add_package "$ws" app-git "$gsa_meta_any"
add_package "$ws" bareapp-git "$gsa_meta_any"
set_topology_record "$ws" app-git git 'libs-git'
set_topology_record "$ws" bareapp-git git ''
mkdir -p "$ws/db/local"

# Payloads: the provider ships usr/lib/libgreet.so.1 (DT_SONAME); the
# consumer's usr/lib/libapp.so.1 NEEDs it for real (linked against it).
printf 'int gsa_probe_anchor;\n' |
    cc -shared -fPIC -x c - -Wl,-soname,libgreet.so.1 -o "$tmp/libgreet.so.1"
mkdir -p "$tmp/payload-libs-git/usr/lib"
cp "$tmp/libgreet.so.1" "$tmp/payload-libs-git/usr/lib/libgreet.so.1"
printf 'pkgname = libs-git\npkgver = 1.0.0-1\nprovides = libgreet.so=1-64\n' \
    >"$tmp/payload-libs-git/.PKGINFO"
mkdir -p "$tmp/payload-app-git/usr/lib"
printf 'extern int gsa_probe_anchor;\nint gsa_probe_consumer(void) { return gsa_probe_anchor; }\n' |
    cc -shared -fPIC -x c - -Wl,-soname,libapp.so.1 -L"$tmp" -Wl,-rpath-link,"$tmp" \
        -l:libgreet.so.1 -o "$tmp/payload-app-git/usr/lib/libapp.so.1"
printf 'pkgname = app-git\npkgver = 1.0.0-1\nprovides = libapp.so=1-64\n' \
    >"$tmp/payload-app-git/.PKGINFO"

# Path-style NEEDED shape (cases I/J, run #119's mujs/mpv class): a
# SONAME-less DSO linked by ABSOLUTE PATH records that path as its DT_NEEDED
# (mujs ships no SONAME and mpv's DT_NEEDED is literally /usr/lib/libmujs.so).
printf 'int gsa_probe_anchor;\n' |
    cc -shared -fPIC -x c - -o "$tmp/libbare.so"
mkdir -p "$tmp/payload-bareapp-git/usr/lib"
printf 'extern int gsa_probe_anchor;\nint gsa_probe_consumer(void) { return gsa_probe_anchor; }\n' |
    cc -shared -fPIC -x c - -x none -Wl,-soname,libbareapp.so.1 -Wl,-rpath-link,"$tmp" \
        "$tmp/libbare.so" -o "$tmp/payload-bareapp-git/usr/lib/libbareapp.so.1"
printf 'pkgname = bareapp-git\npkgver = 1.0.0-1\nprovides = libbareapp.so=1-64\n' \
    >"$tmp/payload-bareapp-git/.PKGINFO"
readelf -dW "$tmp/payload-bareapp-git/usr/lib/libbareapp.so.1" |
    grep -Fq "[$tmp/libbare.so]" ||
    fail "fixture payload is not path-linked (DT_NEEDED lacks $tmp/libbare.so)"

stage_archive() { # ID — build the id's archive beside its recipe.
    tar --zstd -cf "$ws/packages/$1/$1-1.0.0-1-x86_64.pkg.tar.zst" \
        -C "$tmp/payload-$1" .
}

# The pacman stub that fabricates install results: -U records the installed
# archives; the bare `pacman -Qi` full dump prints the pre-existing blocks
# (GSA_FAKE_EXISTING file) plus one block per recorded archive, read from its
# own .PKGINFO. Named queries answer "not installed" so every conservative
# skip/diff path stays out of the way.
cat >"$ws/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'pacman %s\n' "$*" >>"${GSA_FAKE_PACMAN_LOG:?}"
args=()
for a in "$@"; do
    [[ $a == -- ]] && continue
    args+=("$a")
done
case ${args[0]:-} in
-U)
    for a in "${args[@]:1}"; do
        [[ $a == *.pkg.tar.zst ]] || continue
        printf '%s\n' "$a" >>"${GSA_FAKE_DB_DIR:?}/installed.list"
    done
    exit 0
    ;;
-Ql)
    # Fabricated file lists (source (d) of the probe's resolution): the
    # names an installed package owns, one 'pkgname /path' line per file.
    cat "${GSA_FAKE_QL:-/dev/null}" 2>/dev/null
    exit 0
    ;;
-Qi)
    if [[ -z ${args[1]:-} ]]; then
        cat "${GSA_FAKE_EXISTING:?}" 2>/dev/null
        if [[ -f ${GSA_FAKE_DB_DIR:?}/installed.list ]]; then
            while read -r arch; do
                member=$(tar -tf "$arch" 2>/dev/null |
                    awk '$0 == ".PKGINFO" || $0 == "./.PKGINFO" { print; exit }')
                [[ -n $member ]] || continue
                info=$(tar -xOf "$arch" -- "$member" 2>/dev/null)
                printf 'Name : %s\n' \
                    "$(printf '%s\n' "$info" | sed -n 's/^pkgname = //p' | head -1)"
                printf 'Provides : %s\n' \
                    "$(printf '%s\n' "$info" |
                        sed -n 's/^provides = //p' | paste -sd' ' -)"
            done <"$GSA_FAKE_DB_DIR/installed.list"
        fi
        exit 0
    fi
    exit 1
    ;;
esac
exit 1
EOF
chmod +x "$ws/bin/pacman"

cat >"$ws/bin/pacman-conf" <<'EOF'
#!/usr/bin/env bash
set -u
if [[ ${1:-} == DBPath ]]; then
    printf '%s\n' "${GSA_FAKE_DB_PATH:?}"
    exit 0
fi
exit 1
EOF
chmod +x "$ws/bin/pacman-conf"
stub_sudo "$ws"

run_case() { # LABEL — run -ia over whatever archives are staged.
    run_builder env \
        PATH="$ws/bin:$PATH" \
        GSA_STATE_DIR="$ws/state" \
        _IGNOREPKG_CONF="$ws/pacman.conf" \
        GSA_FAKE_PACMAN_LOG="$ws/pacman.log" \
        GSA_FAKE_DB_DIR="$ws/db" \
        GSA_FAKE_DB_PATH="$ws/db" \
        GSA_FAKE_EXISTING="$ws/existing.txt" \
        GSA_FAKE_QL="$ws/ql.txt" \
        GSA_CPU_THREADS=8 GSA_MEMORY_GIB=16 \
        fish "$ws/build-all.fish" --allow-broken-rustc --no-deps --no-sync -ia
}

reset_case() {
    rm -f "$ws/packages"/*/*.pkg.tar.zst "$ws/db/installed.list"
    : >"$ws/pacman.log"
    : >"$ws/ql.txt"
}

# ─── A. clean: the existing set resolves the consumer's NEEDED ─────────────
reset_case
stage_archive libs-git
stage_archive app-git
cat >"$ws/existing.txt" <<'EOF'
Name : preinstalled-runtime
Version : 1-1
Provides : libgreet.so=1-64
EOF
run_case A
((FIXTURE_RC == 0)) ||
    fail "A: a resolved NEEDED must not abort (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
grep -Fq 'post-install NEEDED probe' <<<"$FIXTURE_OUTPUT" &&
    fail "A: no probe output expected on the clean case: $FIXTURE_OUTPUT"
grep -q -- 'pacman -U' "$ws/pacman.log" ||
    fail "A: the transaction never ran: $(cat "$ws/pacman.log")"
checks=$((checks + 3))

# ─── B. unresolved NEEDED → loud abort naming member + soname ─────────────
reset_case
stage_archive app-git
cat >"$ws/existing.txt" <<'EOF'
Name : unrelated
Version : 1-1
Provides : libother.so=9-64
EOF
run_case B
((FIXTURE_RC != 0)) ||
    fail "B: an unresolved NEEDED must abort the run: $FIXTURE_OUTPUT"
grep -q -- 'pacman -U' "$ws/pacman.log" ||
    fail "B: the transaction must land first (the probe is POST-install): $(cat "$ws/pacman.log")"
grep -Fq 'post-install NEEDED probe: usr/lib/libapp.so.1 needs libgreet.so.1' \
    <<<"$FIXTURE_OUTPUT" ||
    fail "B: the abort must name the member and the unresolved soname: $FIXTURE_OUTPUT"
grep -Fq 'aborting — the transaction landed with outputs whose sonames do not resolve' \
    <<<"$FIXTURE_OUTPUT" ||
    fail "B: the abort must say what it stops: $FIXTURE_OUTPUT"
grep -Fq 'All builds succeeded!' <<<"$FIXTURE_OUTPUT" &&
    fail "B: success was reported after the probe failure: $FIXTURE_OUTPUT"
checks=$((checks + 4))

# ─── C. the newly installed set resolves within the same transaction ──────
reset_case
stage_archive libs-git
stage_archive app-git
: >"$ws/existing.txt"
run_case C
((FIXTURE_RC == 0)) ||
    fail "C: the provider's own .PKGINFO provide must resolve the consumer (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
grep -Fq 'post-install NEEDED probe' <<<"$FIXTURE_OUTPUT" &&
    fail "C: no probe output expected: $FIXTURE_OUTPUT"
checks=$((checks + 2))

# ─── D. the exclusions registry is the probe's resolution source (c) ──────
reset_case
stage_archive app-git
cat >>"$ws/config/abi-exclusions.conf" <<'EOF'
libgreet.so|fixture: documented dangling soname|2099-01-01
EOF
cat >"$ws/existing.txt" <<'EOF'
Name : unrelated
Version : 1-1
Provides : libother.so=9-64
EOF
run_case D
((FIXTURE_RC == 0)) ||
    fail "D: a registered soname must resolve for the probe (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
grep -Fq 'post-install NEEDED probe' <<<"$FIXTURE_OUTPUT" &&
    fail "D: no probe output expected with the exclusion registered: $FIXTURE_OUTPUT"
# Leave the registry as we found it: D's entry must not resolve later cases.
sed -i '/^libgreet\.so|/d' "$ws/config/abi-exclusions.conf"
checks=$((checks + 2))

# ─── G. a file owned by an installed package resolves without a provide ────
# 2026-10-06 full build: stock Arch ships libx11/libxt/libxext WITHOUT
# `provides=(libX11.so)`, so a provide-set-only probe aborts every consumer
# of a provider that never declared its soname. The runtime truth is the
# FILE — `pacman -Ql`'s ownership list is what the stub fabricates here.
reset_case
stage_archive app-git
printf 'libx11 /usr/lib/libgreet.so.1\n' >"$ws/ql.txt"
cat >"$ws/existing.txt" <<'EOF'
Name : unrelated
Version : 1-1
Provides : libother.so=9-64
EOF
run_case G
((FIXTURE_RC == 0)) ||
    fail "G: an owned soname file must resolve without a provide (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
grep -Fq 'post-install NEEDED probe' <<<"$FIXTURE_OUTPUT" &&
    fail "G: no probe output expected when the file is owned: $FIXTURE_OUTPUT"
checks=$((checks + 2))

# ─── H. bytes shipped by the same transaction resolve without a provide ────
# A batch mate's private lib (no provide declared) is resolvable from the
# very files the transaction lands — and the name is then owned afterwards.
reset_case
printf 'pkgname = libs-git\npkgver = 1.0.0-1\n' >"$tmp/payload-libs-git/.PKGINFO"
stage_archive libs-git
stage_archive app-git
printf 'pkgname = libs-git\npkgver = 1.0.0-1\nprovides = libgreet.so=1-64\n' \
    >"$tmp/payload-libs-git/.PKGINFO"
: >"$ws/existing.txt"
run_case H
((FIXTURE_RC == 0)) ||
    fail "H: a same-transaction shipped soname must resolve (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
grep -Fq 'post-install NEEDED probe' <<<"$FIXTURE_OUTPUT" &&
    fail "H: no probe output expected when the batch ships the file: $FIXTURE_OUTPUT"
checks=$((checks + 2))

# ─── E. a probe that cannot run is a NAMED warning, never a silent "clean" ──
# R-F26 non-fatal half: mktemp failure (the probe's temp dir) must surface as
# `post-install NEEDED probe skipped (<reason>)` while the run still succeeds
# — the layer reports "unprobed", never "clean". The stub fails ONLY the
# probe's template so no other temp user is collateral.
(
    reset_case
    stage_archive libs-git
    stage_archive app-git
    : >"$ws/existing.txt"
    cat >"$ws/bin/mktemp" <<'EOF'
#!/usr/bin/env bash
case "$*" in
*gsa-abi-probe*) exit 1 ;;
esac
exec /usr/bin/mktemp "$@"
EOF
    chmod +x "$ws/bin/mktemp"
    run_case E-mktemp
    rm -f "$ws/bin/mktemp"
    ((FIXTURE_RC == 0)) ||
        fail "E: a skipped probe is non-fatal (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    grep -Fq 'post-install NEEDED probe skipped' <<<"$FIXTURE_OUTPUT" ||
        fail "E: the skipped probe must be a named warning: $FIXTURE_OUTPUT"
    grep -Fq 'ABI layer did not run' <<<"$FIXTURE_OUTPUT" ||
        fail "E: the warning must say the layer did not run: $FIXTURE_OUTPUT"
    grep -q -- 'pacman -U' "$ws/pacman.log" ||
        fail "E: the transaction must still land before the probe: $(cat "$ws/pacman.log")"
    checks=$((checks + 3))
)

# ─── F. the -ia preflight REFUSES when readelf is missing (R-F26 gate half) ─
# A symlink farm of every /usr/bin tool except readelf pins `command -q
# readelf` to fail without stubbing anything else: the probe's tools are
# prereqs of the install entries (like tar/strings), so an unprobeable host
# refuses up front instead of installing under a silent "clean".
(
    farm="$ws/noreadelf-bin"
    mkdir -p "$farm"
    for tool_bin in /usr/bin/*; do
        tool=${tool_bin##*/}
        [[ $tool == readelf ]] && continue
        ln -s "$tool_bin" "$farm/$tool"
    done
    reset_case
    stage_archive libs-git
    : >"$ws/existing.txt"
    run_builder env \
        PATH="$ws/bin:$farm" \
        GSA_STATE_DIR="$ws/state" \
        _IGNOREPKG_CONF="$ws/pacman.conf" \
        GSA_FAKE_PACMAN_LOG="$ws/pacman.log" \
        GSA_FAKE_DB_DIR="$ws/db" \
        GSA_FAKE_DB_PATH="$ws/db" \
        GSA_FAKE_EXISTING="$ws/existing.txt" \
        GSA_CPU_THREADS=8 GSA_MEMORY_GIB=16 \
        fish "$ws/build-all.fish" --allow-broken-rustc --no-deps --no-sync -ia
    rm -rf -- "$farm"
    ((FIXTURE_RC != 0)) ||
        fail "F: -ia must refuse when readelf is unavailable: $FIXTURE_OUTPUT"
    grep -Fq "required command 'readelf' is unavailable" <<<"$FIXTURE_OUTPUT" ||
        fail "F: the refusal must name readelf: $FIXTURE_OUTPUT"
    if grep -q -- 'pacman -U' "$ws/pacman.log" 2>/dev/null; then
        fail "F: a transaction ran under an unprobeable host: $(cat "$ws/pacman.log")"
    fi
    checks=$((checks + 3))
)

# ─── I. path-style NEEDED resolves via its exact owned path ────────────────
# 2026-10-10 run #119 (mujs/mpv class): mujs ships libmujs.so WITHOUT a
# SONAME, so mpv linked it by absolute path and its DT_NEEDED is literally
# /usr/lib/libmujs.so — no provide and no bare name to match. The runtime
# truth is the exact path: `pacman -Ql` owns /usr/lib/libmujs.so, the loader
# resolves it, so the probe must too.
reset_case
stage_archive bareapp-git
printf 'mujs %s\n' "$tmp/libbare.so" >"$ws/ql.txt"
: >"$ws/existing.txt"
run_case I
((FIXTURE_RC == 0)) ||
    fail "I: a path NEEDED whose exact path is owned must resolve (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
grep -Fq 'post-install NEEDED probe' <<<"$FIXTURE_OUTPUT" &&
    fail "I: no probe output expected when the exact path is owned: $FIXTURE_OUTPUT"
checks=$((checks + 2))

# ─── J. a path NEEDED resolves ONLY by exact path — and stays fail-closed ──
# Same basename owned elsewhere must not satisfy a path-style name (the
# loader opens the literal path), so an unowned path aborts even when a file
# of the same name is owned. Failure names the member and the full path.
reset_case
stage_archive bareapp-git
printf 'elsewhere /opt/elsewhere/libbare.so\n' >"$ws/ql.txt"
: >"$ws/existing.txt"
run_case J
((FIXTURE_RC != 0)) ||
    fail "J: an unowned path NEEDED must abort even with a same-basename file owned: $FIXTURE_OUTPUT"
grep -Fq "usr/lib/libbareapp.so.1 needs $tmp/libbare.so" <<<"$FIXTURE_OUTPUT" ||
    fail "J: the abort must name the member and the full unresolved path: $FIXTURE_OUTPUT"
checks=$((checks + 2))

printf 'abi-postinstall-probe fixture: PASS (%d checks)\n' "$checks"
