#!/usr/bin/env bash
set -euo pipefail

# ABI-drift guard layer 1 — the closure lint (the engine's QA registry check
# `abi-closure`, crates/gsa-qa/src/checks.rs — the port of build-all.fish
# audit_lint_abi_closure, reachable through the hidden `gsa --qa-check
# abi-closure` seam (contract §D.1) and rendered in `gsa -Ma` (§B.7/§E.4).
# The lint works on WORKSPACE-BUILT OUTPUTS (the archives beside each recipe),
# so this fixture synthesizes real archives with real ELF payloads (cc +
# -Wl,-soname, like tests/provides-audit.sh) and pins:
#
#   A. clean: a shipped DT_SONAME covered by a bare soname provide, and a
#      consumer whose DT_NEEDED resolves to (a) that workspace provide and
#      (b) an expected base-system soname → `qa-check abi-closure: clean`;
#   B. provider/consumer violation: the consumer needs libgreet.so.2 while
#      its provider declares the family but ships only libgreet.so.1 — the
#      finding must NAME both sides and the versions;
#   C. no-provider violation: a NEEDED soname that no workspace provide, no
#      base-system entry and no exclusion covers — the finding must name the
#      consumer and point at config/abi-exclusions.conf;
#   D. ship-rule violation: a shipped DT_SONAME with no bare soname provide
#      — the finding must name the provider and the exact declare line;
#   E. the exclusions registry (config/abi-exclusions.conf) is WIRED IN: a
#      soname entry clears (c) and a package-id entry exempts the package;
#   F. `gsa -Ma` renders the closure findings and stays report-only (rc 0
#      with findings);
#   G. no built outputs → the lint reports `skipped`, not `clean`.
#
# Scratch workspaces under $TMPDIR only; the repo tree is never touched.

# Flip notes (docs/gsa-fixture-migration.md row `tests/abi-closure-lint.sh`):
# argv `--audit-lint abi-closure` flips to the hidden `gsa --qa-check
# abi-closure` seam (§D.1; registry name unchanged), `--audit` to `gsa -Ma`
# (§B.7), `--list` to `gsa -Sl` (§B.4). Verdicts re-pin to the seam's output
# contract (§D.1/§E.4): finding lines `<check>: <subject>: <detail>` and the
# `qa-check <name>: clean|N finding(s)|skipped — …` tail; the meaning pins
# below assert the STAGED DATA the findings must carry (ids, members, sonames,
# versions, the declare line) and the class-marker phrases, never whole
# sentences (§L.3 prose byte-pins retire; gap G9: there is no v2 prose spec,
# the single rendering test is tests/gsa-qa-v2.sh's framing pin). The
# report-only meaning keeps (§E.4): findings never change the seam rc (0) and
# `-Ma` exits 0 with findings present. The loader-rejection rc pins §G.1's
# malformed-config class (2). The staged `.PKGINFO` now carries `arch` —
# the engine's discovery refuses metadata it cannot parse (rule 25(h) treats
# such an archive as unreadable), so a payload without it would make the lint
# report `skipped` instead of probing.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/tests/lib/fixture-lib.bash"
source "$root/tests/lib/rr-v2.bash"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-abi-closure-lint.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    printf 'abi-closure-lint fixture: %s\n' "$1" >&2
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
export GSA_STATE_DIR="$tmp/state"

command -v cc >/dev/null 2>&1 || fail 'cc is required to synthesize ELF payloads'
command -v readelf >/dev/null 2>&1 || fail 'readelf is required'

checks=0

# make_lib DIR FILE SONAME — one tiny shared object carrying DT_SONAME and a
# symbol consumers can reference (so the linker cannot drop the dependency).
make_lib() {
    mkdir -p "$1"
    printf 'int gsa_abi_anchor_%s;\n' "${3//[^A-Za-z0-9]/_}" |
        cc -shared -fPIC -x c - -Wl,-soname,"$3" -o "$1/$2"
}

# make_consumer FILE SONAME NEED_DIR NEED_FILE... — a shared object with
# DT_SONAME SONAME and one DT_NEEDED per NEED_FILE (linked against the stub
# copies in NEED_DIR so every NEEDED entry is real).
make_consumer() {
    local out=$1 soname=$2 need_dir=$3
    shift 3
    local refs=() links=() f sym
    for f in "$@"; do
        sym="gsa_abi_anchor_${f//[^A-Za-z0-9]/_}"
        refs+=("extern int $sym;" "int gsa_ref_${f//[^A-Za-z0-9]/_}(void) { return $sym; }")
        links+=(-l:"$f")
    done
    mkdir -p "$(dirname "$out")"
    printf '%s\n' "${refs[@]}" |
        cc -shared -fPIC -x c - -Wl,-soname,"$soname" -L"$need_dir" \
            -Wl,-rpath-link,"$need_dir" "${links[@]}" -o "$out"
}

# make_archive DIR PKGNAME STAGE — a makepkg-shaped archive beside the recipe
# (payload + .PKGINFO), the artifact shape the engine's discovery reads.
make_archive() {
    local dir=$1 name=$2 stage=$3
    {
        printf 'pkgname = %s\n' "$name"
        printf 'pkgver = 1.0.0-1\n'
        printf 'arch = x86_64\n'
    } >"$stage/.PKGINFO"
    tar --zstd -cf "$dir/packages/$name/$name-1.0.0-1-x86_64.pkg.tar.zst" -C "$stage" .
}

# write_srcinfo DIR BASE [EXTRA-LINE...] — committed-.SRCINFO shape.
write_srcinfo() {
    local dir=$1 base=$2
    shift 2
    {
        printf 'pkgbase = %s\n' "$base"
        printf 'pkgname = %s\n' "$base"
        printf '%s\n' "$@"
    } >"$dir/.SRCINFO"
}

# The installed-DB probe answers the fixture's fabricated root, never the
# host's /var/lib/pacman (docs/NOTE.md: fixtures never read host state).
mkdir -p "$tmp/db" "$tmp/bin"
cat >"$tmp/bin/pacman-conf" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = DBPath ] && printf '%s\n' "${GSA_FAKE_DB_PATH:?}"
exit 0
EOF
chmod +x "$tmp/bin/pacman-conf"
export GSA_FAKE_DB_PATH="$tmp/db"
export PATH="$tmp/bin:$PATH"

lint() { # WORKSPACE — run the seam, keep rc/output in FIXTURE_*.
    run_engine "$1" --qa-check abi-closure
}

# ─── shared topology: libs-git provides, app-git consumes ───────────────────
ws="$tmp/ws"
make_workspace "$ws" 1 2 low
add_package "$ws" libs-git "$gsa_meta_any"
add_package "$ws" app-git "$gsa_meta_any"
add_package "$ws" bare-git "$gsa_meta_any"
set_topology_record "$ws" app-git git 'libs-git'

# The provider's payload: usr/lib/libgreet.so.1 (soname libgreet.so.1).
stage="$tmp/stage-libs"
make_lib "$stage/usr/lib" libgreet.so.1 libgreet.so.1
make_archive "$ws" libs-git "$stage"

# The consumer's payload: usr/lib/libapp.so.1 (soname libapp.so.1) linked
# against a link-dir copy of libgreet.so.1 — DT_NEEDED libgreet.so.1.
link="$tmp/link"
make_lib "$link" libgreet.so.1 libgreet.so.1
stage="$tmp/stage-app"
make_consumer "$stage/usr/lib/libapp.so.1" libapp.so.1 "$link" libgreet.so.1
make_archive "$ws" app-git "$stage"

write_srcinfo "$ws/packages/libs-git" libs-git $'\tprovides = libgreet.so'
write_srcinfo "$ws/packages/app-git" app-git $'\tprovides = libapp.so' \
    $'\tdepends = libgreet.so'

# ─── G. no built outputs → skipped (before anything is staged) ─────────────
ws_empty="$tmp/ws-empty"
make_workspace "$ws_empty" 1 2 low
add_package "$ws_empty" lonely-git "$gsa_meta_any"
lint "$ws_empty"
((FIXTURE_RC == 0)) || fail "G: --qa-check must stay report-only (rc=$FIXTURE_RC)"
grep -Fq 'qa-check abi-closure: skipped' <<<"$FIXTURE_OUTPUT" ||
    fail "G: no built outputs must report skipped, got: $FIXTURE_OUTPUT"
grep -Fq 'qa-check abi-closure: clean' <<<"$FIXTURE_OUTPUT" &&
    fail "G: a skipped lint must not claim clean, got: $FIXTURE_OUTPUT"
checks=$((checks + 1))

# ─── A. clean case ─────────────────────────────────────────────────────────
lint "$ws"
((FIXTURE_RC == 0)) || fail "A: --qa-check must stay report-only (rc=$FIXTURE_RC)"
grep -Fq 'qa-check abi-closure: clean' <<<"$FIXTURE_OUTPUT" ||
    fail "A: expected a clean verdict on a resolved closure, got: $FIXTURE_OUTPUT"
checks=$((checks + 1))

# ─── B. wrong-version NEEDED names provider AND consumer ───────────────────
# app-git now needs libgreet.so.2 while its provider ships only
# libgreet.so.1 — the exact silent-break the guard exists to name.
make_lib "$link" libgreet.so.2 libgreet.so.2
stage="$tmp/stage-app-b"
make_consumer "$stage/usr/lib/libapp.so.1" libapp.so.1 "$link" libgreet.so.2
rm -f "$ws/packages/app-git/app-git-1.0.0-1-x86_64.pkg.tar.zst"
make_archive "$ws" app-git "$stage"
lint "$ws"
((FIXTURE_RC == 0)) || fail "B: a finding must not change the seam rc (rc=$FIXTURE_RC)"
b_findings=$(grep -c '^abi-closure: ' <<<"$FIXTURE_OUTPUT" || true)
[[ $b_findings == 1 ]] ||
    fail "B: expected exactly one finding row, got $b_findings: $FIXTURE_OUTPUT"
grep -Eq '^abi-closure: consumer app-git \(' <<<"$FIXTURE_OUTPUT" ||
    fail "B: the finding must name the consumer: $FIXTURE_OUTPUT"
grep -Fq "libgreet.so.2" <<<"$FIXTURE_OUTPUT" ||
    fail "B: the finding must name the needed soname: $FIXTURE_OUTPUT"
grep -Fq 'libs-git: libgreet.so.1' <<<"$FIXTURE_OUTPUT" ||
    fail "B: the finding must name the provider and the version it ships: $FIXTURE_OUTPUT"
checks=$((checks + 3))

# ─── C. no workspace provider at all ───────────────────────────────────────
# The consumer grows a SECOND NEEDED (libghost.so.1) while keeping B's
# libgreet.so.2 — one archive per package, so the live version-skew finding
# must ride along for E to prove the exclusions never erase real violations.
make_lib "$link" libghost.so.1 libghost.so.1
stage="$tmp/stage-app-c"
make_consumer "$stage/usr/lib/libapp.so.1" libapp.so.1 "$link" libgreet.so.2 libghost.so.1
rm -f "$ws/packages/app-git/app-git-1.0.0-1-x86_64.pkg.tar.zst"
make_archive "$ws" app-git "$stage"
lint "$ws"
grep -Eq '^abi-closure: consumer app-git \(' <<<"$FIXTURE_OUTPUT" ||
    fail "C: the finding must name the consumer: $FIXTURE_OUTPUT"
grep -Fq "libghost.so.1" <<<"$FIXTURE_OUTPUT" ||
    fail "C: the finding must name the uncovered soname: $FIXTURE_OUTPUT"
grep -Fq 'config/abi-exclusions.conf' <<<"$FIXTURE_OUTPUT" ||
    fail "C: the finding must point at the exclusions registry: $FIXTURE_OUTPUT"
checks=$((checks + 3))

# ─── D. shipped soname without its bare provide ────────────────────────────
stage="$tmp/stage-bare"
make_lib "$stage/usr/lib" libbare.so.3 libbare.so.3
make_archive "$ws" bare-git "$stage"
write_srcinfo "$ws/packages/bare-git" bare-git
lint "$ws"
grep -Fq "provider bare-git" <<<"$FIXTURE_OUTPUT" ||
    fail "D: the ship rule must name the provider: $FIXTURE_OUTPUT"
grep -Fq "usr/lib/libbare.so.3" <<<"$FIXTURE_OUTPUT" ||
    fail "D: the ship rule must name the payload: $FIXTURE_OUTPUT"
grep -Fq "declare provides=('libbare.so')" <<<"$FIXTURE_OUTPUT" ||
    fail "D: the ship rule must name the exact declare line: $FIXTURE_OUTPUT"
checks=$((checks + 3))

# ─── E. the exclusions registry is wired into the guard ────────────────────
# A soname entry clears resolution source (c); a package-id entry exempts the
# package's outputs entirely. Both come from config/abi-exclusions.conf —
# the same strict-loader file the loader validates on every run.
cat >>"$ws/config/abi-exclusions.conf" <<'EOF'
libghost.so|fixture: documented dangling soname|2099-01-01
bare-git|fixture: payload not auditable|2099-01-01
EOF
lint "$ws"
grep -Fq 'libghost.so' <<<"$FIXTURE_OUTPUT" &&
    fail "E: a registered soname must not be reported: $FIXTURE_OUTPUT"
grep -Fq 'bare-git' <<<"$FIXTURE_OUTPUT" &&
    fail "E: a registered package must not be reported: $FIXTURE_OUTPUT"
grep -Fq "libgreet.so.2" <<<"$FIXTURE_OUTPUT" ||
    fail "E: the real violation must survive the exclusions: $FIXTURE_OUTPUT"
checks=$((checks + 3))

# A malformed registry entry breaks every command (strict loader, like
# topology.conf) — the registry must never silently misparse.
printf 'no-pipes-here\n' >>"$ws/config/abi-exclusions.conf"
run_engine "$ws" -Sl
((FIXTURE_RC == 2)) || fail "E: a malformed exclusions entry must fail the loader (rc 2, §G.1), got $FIXTURE_RC"
grep -Fq 'invalid abi-exclusions entry' <<<"$FIXTURE_OUTPUT" ||
    fail "E: the loader must name the malformed entry: $FIXTURE_OUTPUT"
checks=$((checks + 2))

# ─── F. `gsa -Ma` renders the findings, report-only ────────────────────────
# Restore the clean registry line for the audit run (the malformed line above
# would fail the loader).
sed -i '$d' "$ws/config/abi-exclusions.conf"
run_engine "$ws" -Ma
((FIXTURE_RC == 0)) ||
    fail "F: -Ma must stay report-only while findings exist (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
grep -Eq '^audit recipe-contract (clean|[0-9]+ finding\(s\))$' <<<"$FIXTURE_OUTPUT" ||
    fail "F: -Ma must render the recipe-contract QA family summary: $FIXTURE_OUTPUT"
grep -Fq "recipe-contract abi-closure: consumer app-git (" <<<"$FIXTURE_OUTPUT" ||
    fail "F: -Ma must carry the closure findings: $FIXTURE_OUTPUT"
grep -Fq "libgreet.so.2" <<<"$FIXTURE_OUTPUT" ||
    fail "F: -Ma must name the uncovered soname: $FIXTURE_OUTPUT"
checks=$((checks + 3))

printf 'abi-closure-lint fixture: PASS (%d checks)\n' "$checks"
