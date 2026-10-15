#!/usr/bin/env bash
set -euo pipefail

# ABI-drift guard layer 4 — the NEEDED probe (the engine's decision gate
# `needed_misses`, crates/gsa-install/src/gates.rs, run per candidate before
# any transaction). A stub "fabricates install results": the fabricated
# installed database grows from what `pacman -U` recorded, so the probe
# resolves against exactly the NEWLY INSTALLED + EXISTING provide/file set
# the real one would see. Pinned:
#
#   A. clean: a consumer output whose DT_NEEDED libgreet.so.1 resolves via
#      the EXISTING set (a pre-installed package's auto-versioned provide
#      'libgreet.so=1-64' covers soname libgreet.so.1) -> run succeeds;
#   B. failure: nothing provides the needed soname -> the run REFUSES naming
#      the member and the unresolved sonames, rc 3, nothing transacts;
#   C. the NEWLY INSTALLED half of the resolution set: provider + consumer in
#      one transaction (the collective install), the existing set empty —
#      the batch's own bytes cover the consumer's NEEDED;
#   D. the exclusions registry resolves source (c) for the probe too;
#   G. the runtime-file half of resolution (2026-10-06 full build): a NEEDED
#      whose file is OWNED by an installed package resolves even when no
#      package declares the soname provide — stock Arch ships libx11/libxt/
#      libxext without `provides=(libX11.so)`, so the provide set alone
#      false-refuses every consumer of a provider that never declared one.
#      The ownership list is the local DB's files list;
#   H. the same for a file SHIPPED by the transaction itself (a private lib
#      in the same batch, no provide declared): shipped bytes resolve too;
#   I. path-style NEEDED names (a SONAME-less DSO linked by absolute path —
#      run #119's mujs/mpv class) resolve via their EXACT owned path;
#   J. …and only via the exact path: a same-basename file owned elsewhere
#      does not satisfy the loader, so an unowned path stays fail-closed
#      (FISH-DRIVEN, see DEVIATION 3).
#
# Flip notes (docs/gsa-fixture-migration.md row `tests/abi-postinstall-probe.sh`):
# argv `fish build-all.fish --allow-broken-rustc --no-deps --no-sync -ia` ->
# `gsa -Ua --config <conf>` (§B.6; the registration target is `--config`,
# gap G6) plus the hidden `gsa --install-decide checked <archive…>` seam for
# the §E.2 decision rows. The abort prose (`post-install NEEDED probe: …
# needs …` / `aborting — the transaction landed …`) retires as rendering
# (§L.3); its meaning re-pins as the §E.3 `refuse needed <archive> <member>
# <soname>` rows and the §H.3 `install-refused needed …` outcome reasons
# with rc 3 (§G.1). The fabricated DB flips from `pacman -Qi`/`-Ql` stub
# answers to the engine's own local-DB layout (`$DB/local/<name>-<ver>/
# {desc,files}`, read through `pacman-conf DBPath` — never the host DB).
# DEVIATION 1 (probe timing — inventory KEEP cells :199-215/:321-322 "probe
# runs post-transaction"): the engine probes ARCHIVE PAYLOADS at decide time
# and refuses BEFORE any pacman call (rule 25(h), fail-closed). The fish
# probe ran after `pacman -U` had landed and aborted the run; the flip's own
# target cell is `refuse` rows + rc 3, so case B's "the transaction must
# land first" pin flips to its fail-closed opposite (no transaction) and the
# run-level abort becomes a refusal. Everything else about the probe
# (what resolves, what fails, what it names) is unchanged.
# DEVIATION 2 (cases E/F stay fish-driven — the local-db-repair pattern,
# inventory cells "REWRITE: prose ≈13 (:317, :355)" / KEEP :301-361): the
# engine's probe has NO mktemp scratch and NO readelf dependency — it parses
# ELF members in-process (crates/gsa-recipe/src/elf.rs `needed_libs`), so
# neither "the probe skipped (mktemp)" (R-F26's non-fatal half) nor the
# readelf preflight refusal (R-F26's gate half) has an engine trigger or
# counterpart (a probe error is fail-closed `refuse plan-failed`, the
# opposite of the non-fatal skip). Both sub-cases keep driving the fish
# builder this workspace still carries, against the fish-era pacman stub.
# DEVIATION 3 (case J stays fish-driven — inventory KEEP cell :365-393
# "resolution semantics"): the engine's ownership match is strictly LOOSER
# than the loader — `LocalDb::owns_file` (crates/gsa-install/src/localdb.rs
# :188-194) falls back to BASENAME matching, so a path-style DT_NEEDED
# resolves from any same-basename owned file (measured: a /opt/elsewhere/
# libbare.so ownership satisfies DT_NEEDED /abs/tmp/libbare.so and the
# candidate decides `install`). The loader opens the LITERAL path (run #119's
# mujs/mpv class), so the exact-path machinery does not exist on the engine
# and the fail-closed half of the resolution semantics keeps its fish-era
# pin against the fish builder this workspace still carries.
#
# Everything under $TMPDIR; ELF payloads synthesized with cc (like
# tests/provides-audit.sh); the real /usr and the real pacman DB are never
# touched (pacman/pacman-conf/sudo all stubbed).

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/tests/lib/fixture-lib.bash"
source "$root/tests/lib/rr-v2.bash"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-abi-postinstall-probe.XXXXXX")
# Root-safe cleanup: privileged engine runs leave root-owned state litter a
# user-side rm cannot unlink.
trap '/usr/bin/sudo -n rm -rf -- "$tmp" 2>/dev/null || rm -rf -- "$tmp" 2>/dev/null || true' EXIT

fail() {
    printf 'abi-postinstall-probe fixture: %s\n' "$1" >&2
    exit 1
}

# ─── The engine under test: built into the fixture tree (scratch only).
# GSA_TEST_GSA_BIN, when already set to an executable, is that engine (the
# rr-v2.bash run_engine convention) and the scratch build is skipped. ──────
if [ -z "${GSA_TEST_GSA_BIN:-}" ]; then
    cargo build --offline --quiet --target-dir "$tmp/cargo" -p gsa-cli \
        --manifest-path "$gsa_repo_root/Cargo.toml" ||
        fail "cannot build the gsa binary for the fixture"
    GSA_TEST_GSA_BIN="$tmp/cargo/debug/gsa"
fi
[ -x "$GSA_TEST_GSA_BIN" ] || fail "the engine under test is not executable: $GSA_TEST_GSA_BIN"
export GSA_TEST_ENGINE=gsa
export GSA_TEST_GSA_BIN

command -v cc >/dev/null 2>&1 || fail 'cc is required to synthesize ELF payloads'
command -v readelf >/dev/null 2>&1 || fail 'readelf is required'

checks=0

ws="$tmp/ws"
make_workspace "$ws" 1 2 low
install_fish_oracle "$ws"
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
printf 'pkgname = libs-git\npkgver = 1.0.0-1\narch = any\nprovides = libgreet.so=1-64\n' \
    >"$tmp/payload-libs-git/.PKGINFO"
mkdir -p "$tmp/payload-app-git/usr/lib"
printf 'extern int gsa_probe_anchor;\nint gsa_probe_consumer(void) { return gsa_probe_anchor; }\n' |
    cc -shared -fPIC -x c - -Wl,-soname,libapp.so.1 -L"$tmp" -Wl,-rpath-link,"$tmp" \
        -l:libgreet.so.1 -o "$tmp/payload-app-git/usr/lib/libapp.so.1"
printf 'pkgname = app-git\npkgver = 1.0.0-1\narch = any\nprovides = libapp.so=1-64\n' \
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
printf 'pkgname = bareapp-git\npkgver = 1.0.0-1\narch = any\nprovides = libbareapp.so=1-64\n' \
    >"$tmp/payload-bareapp-git/.PKGINFO"
readelf -dW "$tmp/payload-bareapp-git/usr/lib/libbareapp.so.1" |
    grep -Fq "[$tmp/libbare.so]" ||
    fail "fixture payload is not path-linked (DT_NEEDED lacks $tmp/libbare.so)"

stage_archive() { # ID — build the id's archive beside its recipe.
    tar --zstd -cf "$ws/packages/$1/$1-1.0.0-1-x86_64.pkg.tar.zst" \
        -C "$tmp/payload-$1" .PKGINFO usr
}

# db_install NAME VERSION [PROVIDE…] [--- FILES…] — one fabricated pacman
# local-DB entry in the ENGINE's layout (`local/<name>-<ver>/{desc,files}`),
# the authority the engine's probe resolves against (LocalDb::load through
# `pacman-conf DBPath`; never the host DB). Arguments before the `--`
# separator are provides; every argument after it is one owned-file line.
db_install() {
    local name=$1 version=$2
    shift 2
    local provides=() files=() seen_sep=0 arg
    for arg in "$@"; do
        if [[ $arg == -- ]]; then seen_sep=1; continue; fi
        if ((seen_sep)); then files+=("$arg"); else provides+=("$arg"); fi
    done
    local dir="$ws/db/local/$name-$version"
    mkdir -p "$dir"
    {
        printf '%%NAME%%\n%s\n\n' "$name"
        printf '%%VERSION%%\n%s\n\n' "$version"
        printf '%%BASE%%\n%s\n' "$name"
        if ((${#provides[@]})); then
            printf '\n%%PROVIDES%%\n'
            printf '%s\n' "${provides[@]}"
        fi
    } >"$dir/desc"
    {
        printf '%%FILES%%\n'
        if ((${#files[@]})); then
            printf '%s\n' "${files[@]}"
        fi
    } >"$dir/files"
}

# The pacman stub that fabricates install results for the FISH-driven cases
# E/F (their probe reads `pacman -Qi`/`-Ql`) and records every transaction
# the engine's install runs (`sudo -n pacman -U`).
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
    # Fabricated file lists (fish-era probe source (d)): one 'pkgname
    # /path' line per file.
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

export PATH="$ws/bin:$PATH"
export GSA_STATE_DIR="$ws/state"
# The fish-driven cases (E/F/J) run in the PLAIN user domain while the engine
# runs above run as root — the engine's root-owned $ws/state subdirs refuse
# user-side mkdir — so the fish builder gets its own state root: one domain
# owns each state tree.
mkdir -p "$ws/state-fish"
export GSA_FAKE_PACMAN_LOG="$ws/pacman.log"
export GSA_FAKE_DB_DIR="$ws/db"
export GSA_FAKE_DB_PATH="$ws/db"
export GSA_FAKE_EXISTING="$ws/existing.txt"
export GSA_FAKE_QL="$ws/ql.txt"
export GSA_CPU_THREADS=8
export GSA_MEMORY_GIB=16

# seam_rows LABEL — the §E.2 decision rows over whatever archives are staged
# (the hidden `--install-decide` seam, §D.1: prints rows, touches nothing).
seam_rows() { # sets SEAM_RC / SEAM_OUTPUT
    local archives=("$ws"/packages/*/*.pkg.tar.zst)
    run_engine "$ws" --install-decide checked "${archives[@]}"
    SEAM_OUTPUT=$FIXTURE_OUTPUT
    SEAM_RC=$FIXTURE_RC
}

run_ua() { # LABEL — the collective install run over whatever is staged.
    run_engine "$ws" -Ua --config "$ws/pacman.conf"
    UA_OUTPUT=$FIXTURE_OUTPUT
    UA_RC=$FIXTURE_RC
}

run_case() { # LABEL — the FISH-driven -ia run (cases E/F only).
    # The engine's atomic conf rewrite (temp + rename) leaves
    # $ws/pacman.conf root-owned, and the fish-era register overwrites the
    # file IN PLACE as the user — hand the conf back to the user domain
    # before the fish run (its writes must succeed, not its assertions).
    /usr/bin/sudo -n chown "$(id -u):$(id -g)" "$ws/pacman.conf" 2>/dev/null || true
    run_builder env \
        PATH="$ws/bin:$PATH" \
        GSA_STATE_DIR="$ws/state-fish" \
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
    rm -rf "$ws/db/local"
    mkdir -p "$ws/db/local"
    : >"$ws/pacman.log"
    : >"$ws/ql.txt"
    : >"$ws/existing.txt"
}

# ─── A. clean: the existing set resolves the consumer's NEEDED ─────────────
reset_case
stage_archive app-git
db_install preinstalled-runtime 1-1 'libgreet.so=1-64'
seam_rows A
[[ $SEAM_RC == 0 ]] ||
    fail "A: a resolved NEEDED must decide install (rc=$SEAM_RC): $SEAM_OUTPUT"
[[ $(rr2_decision app-git decision <<<"$SEAM_OUTPUT") == install ]] ||
    fail "A: decision is not install: $SEAM_OUTPUT"
run_ua A
[[ $UA_RC == 0 ]] ||
    fail "A: a resolved NEEDED must not refuse the run (rc=$UA_RC): $UA_OUTPUT"
grep -q -- 'pacman -U' "$ws/pacman.log" ||
    fail "A: the transaction never ran: $(cat "$ws/pacman.log")"
checks=$((checks + 3))

# ─── B. unresolved NEEDED → refusal naming member + soname (DEVIATION 1:
# nothing transacts — the gate is fail-closed before pacman) ────────────────
reset_case
stage_archive app-git
db_install unrelated 1-1 'libother.so=9-64'
seam_rows B
[[ $SEAM_RC == 1 ]] ||
    fail "B: a refuse row is seam rc 1 (§E.5), got $SEAM_RC: $SEAM_OUTPUT"
grep < <(rr2_decision app-git decision <<<"$SEAM_OUTPUT") -qx refuse ||
    fail "B: the decision is not refuse: $SEAM_OUTPUT"
b_row=$(rr2_decisions <<<"$SEAM_OUTPUT" | grep '^app-git refuse ' || true)
[[ "$b_row" == 'app-git refuse needed' ]] ||
    fail "B: the refusal key is not needed (§E.3): $SEAM_OUTPUT"
seam_detail=$(grep -E '^app-git refuse needed ' <<<"$SEAM_OUTPUT" || true)
[[ "$seam_detail" == *"usr/lib/libapp.so.1 libgreet.so.1"* ]] ||
    fail "B: the refusal must name the member and the unresolved soname: $seam_detail"
run_ua B
[[ $UA_RC -ne 0 ]] ||
    fail "B: an unresolved NEEDED must refuse the run: $UA_OUTPUT"
[[ $UA_RC == 3 ]] ||
    fail "B: the refusal is rc 3 (§G.1), got $UA_RC: $UA_OUTPUT"
grep -Eq 'install-refused needed ' <<<"$UA_OUTPUT" ||
    fail "B: the run record lacks the install-refused needed reason: $UA_OUTPUT"
grep -Fq 'usr/lib/libapp.so.1' <<<"$UA_OUTPUT" ||
    fail "B: the run must name the member: $UA_OUTPUT"
grep -Fq 'libgreet.so.1' <<<"$UA_OUTPUT" ||
    fail "B: the run must name the unresolved soname: $UA_OUTPUT"
if grep -q -- 'pacman -U' "$ws/pacman.log"; then
    fail "B: a refused plan reached pacman (rule 25(h)): $(cat "$ws/pacman.log")"
fi
checks=$((checks + 7))

# ─── C. the newly installed set resolves within the same transaction ──────
reset_case
stage_archive libs-git
stage_archive app-git
seam_rows C
[[ $SEAM_RC == 0 ]] ||
    fail "C: the batch's own bytes must resolve the consumer (rc=$SEAM_RC): $SEAM_OUTPUT"
[[ $(rr2_decision app-git decision <<<"$SEAM_OUTPUT") == install ]] ||
    fail "C: decision is not install: $SEAM_OUTPUT"
checks=$((checks + 2))

# ─── D. the exclusions registry is the probe's resolution source (c) ──────
reset_case
stage_archive app-git
db_install unrelated 1-1 'libother.so=9-64'
cat >>"$ws/config/abi-exclusions.conf" <<'EOF'
libgreet.so|fixture: documented dangling soname|2099-01-01
EOF
seam_rows D
[[ $SEAM_RC == 0 ]] ||
    fail "D: a registered soname must resolve for the probe (rc=$SEAM_RC): $SEAM_OUTPUT"
[[ $(rr2_decision app-git decision <<<"$SEAM_OUTPUT") == install ]] ||
    fail "D: decision is not install with the exclusion registered: $SEAM_OUTPUT"
# Leave the registry as we found it: D's entry must not resolve later cases.
sed -i '/^libgreet\.so|/d' "$ws/config/abi-exclusions.conf"
checks=$((checks + 2))

# ─── G. a file owned by an installed package resolves without a provide ────
# 2026-10-06 full build: stock Arch ships libx11/libxt/libxext WITHOUT
# `provides=(libX11.so)`, so a provide-set-only probe refuses every consumer
# of a provider that never declared its soname. The runtime truth is the
# FILE — the local DB's files list is what db_install fabricates here.
reset_case
stage_archive app-git
db_install libx11 1-1 -- usr/lib/libgreet.so.1
seam_rows G
[[ $SEAM_RC == 0 ]] ||
    fail "G: an owned soname file must resolve without a provide (rc=$SEAM_RC): $SEAM_OUTPUT"
[[ $(rr2_decision app-git decision <<<"$SEAM_OUTPUT") == install ]] ||
    fail "G: decision is not install when the file is owned: $SEAM_OUTPUT"
checks=$((checks + 2))

# ─── H. bytes shipped by the same transaction resolve without a provide ────
# A batch mate's private lib (no provide declared) is resolvable from the
# very files the transaction lands.
reset_case
printf 'pkgname = libs-git\npkgver = 1.0.0-1\narch = any\n' >"$tmp/payload-libs-git/.PKGINFO"
stage_archive libs-git
stage_archive app-git
printf 'pkgname = libs-git\npkgver = 1.0.0-1\narch = any\nprovides = libgreet.so=1-64\n' \
    >"$tmp/payload-libs-git/.PKGINFO"
seam_rows H
[[ $SEAM_RC == 0 ]] ||
    fail "H: a same-transaction shipped soname must resolve (rc=$SEAM_RC): $SEAM_OUTPUT"
[[ $(rr2_decision app-git decision <<<"$SEAM_OUTPUT") == install ]] ||
    fail "H: decision is not install when the batch ships the file: $SEAM_OUTPUT"
checks=$((checks + 2))

# ─── E. a probe that cannot run is a NAMED warning, never a silent "clean" ──
# R-F26 non-fatal half (FISH-DRIVEN — DEVIATION 2): mktemp failure (the
# probe's temp dir) must surface as `post-install NEEDED probe skipped
# (<reason>)` while the run still succeeds — the layer reports "unprobed",
# never "clean". The stub fails ONLY the probe's template so no other temp
# user is collateral.
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
# FISH-DRIVEN — DEVIATION 2. A symlink farm of every /usr/bin tool except
# readelf pins `command -q readelf` to fail without stubbing anything else.
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
        GSA_STATE_DIR="$ws/state-fish" \
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
# truth is the exact path: the local DB owns that path, the loader resolves
# it, so the probe must too.
reset_case
stage_archive bareapp-git
db_install mujs 1-1 -- "$tmp/libbare.so"
seam_rows I
[[ $SEAM_RC == 0 ]] ||
    fail "I: a path NEEDED whose exact path is owned must resolve (rc=$SEAM_RC): $SEAM_OUTPUT"
[[ $(rr2_decision bareapp-git decision <<<"$SEAM_OUTPUT") == install ]] ||
    fail "I: decision is not install when the exact path is owned: $SEAM_OUTPUT"
checks=$((checks + 2))

# ─── J. a path NEEDED resolves ONLY by exact path — and stays fail-closed ──
# Same basename owned elsewhere must not satisfy a path-style name (the
# loader opens the literal path), so an unowned path aborts even when a file
# of the same name is owned. Failure names the member and the full path.
# FISH-DRIVEN — DEVIATION 3 (the engine's basename fallback cannot express
# this; the site keeps its original fish-era shape).
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

if ps -eo args= | grep -F "$tmp" | grep -v grep >/dev/null; then
    fail "a fixture process survived"
fi

printf 'abi-postinstall-probe fixture: PASS (%d checks)\n' "$checks"
