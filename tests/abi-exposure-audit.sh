#!/usr/bin/env bash
set -euo pipefail

# ABI-drift guard layer 5 — the exposure audit (the engine's QA registry check
# `abi-exposure`, crates/gsa-qa/src/checks.rs — the port of build-all.fish
# audit_lint_abi_exposure, reachable through the hidden `gsa --qa-check
# abi-exposure` seam (contract §D.1) and rendered in `gsa -Ma` (§B.7/§E.4);
# report-only everywhere). For every workspace lib whose soname provides
# (committed .SRCINFO bare stems) differ from the installed stock equivalent
# (the installed database's answer for the suffix-stripped stock name), it
# reports the provider → exposed-consumer mapping: one row per drifted
# provide per installed consumer whose depends reach the drift (the drifted
# soname name or the stock name), `-> none` when nothing installed depends on
# it. Pinned here (stubbed `pacman-conf` — the fixture fabricates the
# installed database as a `local/` tree):
#
#   A. output shape: stock-only and house-only drift rows, each naming
#      provider → exposed consumer, with the exact drift spelled out;
#   B. no drift (stem sets equal) → `qa-check abi-exposure: clean`;
#   C. no installed stock equivalent → `skipped`, not `clean`;
#   D. report-only: findings never change the rc, and `gsa -Ma` renders the
#      findings.
#
# Scratch workspace under $TMPDIR only; the real pacman DB is never read.

# Flip notes (docs/gsa-fixture-migration.md row `tests/abi-exposure-audit.sh`):
# argv `--audit-lint abi-exposure` flips to `gsa --qa-check abi-exposure`
# (§D.1; registry name unchanged) and `--audit` to `gsa -Ma` (§B.7). The
# fabricated installed database flips from a `pacman -Qi` stub dump to the
# engine's actual reader shape — a `<db>/local/<name>-<ver>/{desc,files}`
# tree behind a `pacman-conf DBPath` stub (crates/gsa-install/src/localdb.rs:
# the seam shells pacman-conf, never pacman, and falls back to the host DB —
# the stub keeps it inside the fixture tree). The REWRITE prose sites —
# including the old FULL-OUTPUT byte-equality — retire as rendering (§L.3):
# expectations re-pin as §E.4 finding rows (`<check>: <subject>: <detail>`)
# with the staged data (provider id, consumer names, drift values) as the
# meaning pins and the row count DERIVED from the staged scenario (two drift
# directions × their exposed consumers), cross-checked against the seam's
# tally. The drift detail wording is the engine's (identical to fish's); the
# byte-exact row block is not pinned.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/tests/lib/fixture-lib.bash"
source "$root/tests/lib/rr-v2.bash"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-abi-exposure-audit.XXXXXX")
trap '/usr/bin/sudo -n rm -rf -- "$tmp" 2>/dev/null || rm -rf -- "$tmp" 2>/dev/null || true' EXIT

fail() {
    printf 'abi-exposure-audit fixture: %s\n' "$1" >&2
    exit 1
}

# ─── The engine under test: the INSTALLED binary (contract §L.10 — smoke
# test what the user runs — never a nested target/ build). GSA_TEST_GSA_BIN
# is the explicit pre-install override (rr-v2.bash run_engine convention). ──────
if [ -z "${GSA_TEST_GSA_BIN:-}" ]; then
    GSA_TEST_GSA_BIN=$(command -v gsa) || {
        printf 'contract §L.10: no installed gsa on PATH — install gsa-pm, or set GSA_TEST_GSA_BIN explicitly\n' >&2
        exit 1
    }
fi
[ -x "$GSA_TEST_GSA_BIN" ] || fail "the engine under test is not executable: $GSA_TEST_GSA_BIN"
export GSA_TEST_ENGINE=gsa
export GSA_TEST_GSA_BIN
export GSA_STATE_DIR="$tmp/state"

checks=0

ws="$tmp/ws"
make_workspace "$ws" 1 2 low
add_package "$ws" libs-git "$gsa_meta_any"
{
    printf 'pkgbase = libs-git\n'
    printf 'pkgname = libs-git\n'
    printf '\tprovides = libgreet.so\n'
    printf '\tprovides = libnew.so\n'
} >"$ws/packages/libs-git/.SRCINFO"

# db_install DBROOT NAME VERSION [PROVIDE…] [ — DEPEND…] — one fabricated
# pacman local-DB entry (`<db>/local/<name>-<ver>/{desc,files}`), the shape
# crates/gsa-install/src/localdb.rs reads (docs/NOTE.md: fixtures never read
# host state). The entries after a lone `--` are %DEPENDS% rows.
db_install() {
    local db=$1 name=$2 version=$3
    shift 3
    local provides=() depends=() seen_sep=0 arg
    for arg in "$@"; do
        if [[ $arg == -- ]]; then
            seen_sep=1
            continue
        fi
        if ((seen_sep)); then depends+=("$arg"); else provides+=("$arg"); fi
    done
    local dir="$db/local/$name-$version"
    mkdir -p "$dir"
    {
        printf '%%NAME%%\n%s\n\n' "$name"
        printf '%%VERSION%%\n%s\n\n' "$version"
        printf '%%BASE%%\n%s\n' "$name"
        if ((${#provides[@]})); then
            printf '\n%%PROVIDES%%\n'
            printf '%s\n' "${provides[@]}"
        fi
        if ((${#depends[@]})); then
            printf '\n%%DEPENDS%%\n'
            printf '%s\n' "${depends[@]}"
        fi
    } >"$dir/desc"
    printf '%%FILES%%\n' >"$dir/files"
}

# The `pacman-conf` stub answers DBPath with the fixture's fabricated root,
# never the host's /var/lib/pacman (the engine's reader falls back to it).
mkdir -p "$tmp/bin"
cat >"$tmp/bin/pacman-conf" <<'EOF'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = DBPath ]; then
    printf '%s\n' "${GSA_FAKE_DB_PATH:?}"
    exit 0
fi
exit 1
EOF
chmod +x "$tmp/bin/pacman-conf"
export GSA_FAKE_DB_PATH="$tmp/db"
export PATH="$tmp/bin:$PATH"

run_lint() {
    run_engine "$ws" --qa-check abi-exposure
}

# The fabricated installed database: one exposed consumer per drift direction,
# one exposed via the stock NAME, one unexposed bystander.
seed_db() {
    rm -rf "$tmp/db"
    db_install "$tmp/db" oldapp 1-1 '' -- 'libold.so=0-64'
    db_install "$tmp/db" newapp 1-1 '' -- 'libnew.so'
    db_install "$tmp/db" stockfan 1-1 '' -- 'libs>=0.5'
    db_install "$tmp/db" other 1-1 '' -- 'glibc'
}

# The installed stock surface: carries libgreet.so (still there) and
# libold.so (dropped by the workspace recipe). The house surface adds
# libnew.so. So: libold.so=0-64 is stock-only, libnew.so is house-only.
seed_stock() {
    db_install "$tmp/db" libs 1-1 'libgreet.so=1-64' 'libold.so=0-64'
}

seed_db
seed_stock

# ─── A. output shape: provider → exposed consumer rows ─────────────────────
run_lint
((FIXTURE_RC == 0)) ||
    fail "A: --qa-check must stay report-only (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
expected_rows=(
    "abi-exposure: libs-git -> newapp: libs-git carries 'libnew.so' that stock libs does not"
    "abi-exposure: libs-git -> oldapp: stock libs carries 'libold.so=0-64' but libs-git drops it"
    "abi-exposure: libs-git -> stockfan: libs-git carries 'libnew.so' that stock libs does not"
    "abi-exposure: libs-git -> stockfan: stock libs carries 'libold.so=0-64' but libs-git drops it"
)
for row in "${expected_rows[@]}"; do
    grep -Fqx "$row" <<<"$FIXTURE_OUTPUT" ||
        fail "A: missing exposure row.
want:
$row
got:
$FIXTURE_OUTPUT"
done
row_count=$(grep -c '^abi-exposure: ' <<<"$FIXTURE_OUTPUT" || true)
[[ $row_count == ${#expected_rows[@]} ]] ||
    fail "A: expected exactly ${#expected_rows[@]} exposure rows (2 drifts × their exposed consumers), got $row_count: $FIXTURE_OUTPUT"
grep -Fqx "qa-check abi-exposure: ${#expected_rows[@]} finding(s)" <<<"$FIXTURE_OUTPUT" ||
    fail "A: the tally must agree with the derived row count: $FIXTURE_OUTPUT"
if grep -Fq ' -> other' <<<"$FIXTURE_OUTPUT"; then
    fail "A: an unexposed bystander must not be mapped: $FIXTURE_OUTPUT"
fi
checks=$((checks + 3))

# ─── B. no drift → clean ───────────────────────────────────────────────────
# House surface trimmed to the stock's stems (libgreet.so + libold.so); the
# stock's auto-versioned entries still normalize to the same bare stems, so
# nothing differs.
printf 'pkgbase = libs-git\npkgname = libs-git\n\tprovides = libgreet.so\n\tprovides = libold.so\n' \
    >"$ws/packages/libs-git/.SRCINFO"
run_lint
grep -Fq 'qa-check abi-exposure: clean' <<<"$FIXTURE_OUTPUT" ||
    fail "B: an unchanged stem set must be clean: $FIXTURE_OUTPUT"
checks=$((checks + 1))

# ─── C. no installed stock equivalent → skipped ────────────────────────────
seed_db
run_lint
grep -Fq 'qa-check abi-exposure: skipped' <<<"$FIXTURE_OUTPUT" ||
    fail "C: nothing installed to compare must report skipped: $FIXTURE_OUTPUT"
grep -Fq 'qa-check abi-exposure: clean' <<<"$FIXTURE_OUTPUT" &&
    fail "C: a skipped lint must not claim clean: $FIXTURE_OUTPUT"
checks=$((checks + 1))

# ─── D. `gsa -Ma` renders the findings; findings stay report-only ──────────
seed_stock
printf 'pkgbase = libs-git\npkgname = libs-git\n\tprovides = libgreet.so\n\tprovides = libnew.so\n' \
    >"$ws/packages/libs-git/.SRCINFO"
run_engine "$ws" -Ma
((FIXTURE_RC == 0)) ||
    fail "D: -Ma must stay report-only while findings exist (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
grep -Eq '^audit recipe-contract (clean|[0-9]+ finding\(s\))$' <<<"$FIXTURE_OUTPUT" ||
    fail "D: -Ma must render the recipe-contract QA family summary: $FIXTURE_OUTPUT"
grep -Fq 'recipe-contract abi-exposure: libs-git -> oldapp' <<<"$FIXTURE_OUTPUT" ||
    fail "D: -Ma must carry the exposure rows: $FIXTURE_OUTPUT"
grep -Fq "stock libs carries 'libold.so=0-64' but libs-git drops it" <<<"$FIXTURE_OUTPUT" ||
    fail "D: -Ma must spell out the drift: $FIXTURE_OUTPUT"
checks=$((checks + 3))

printf 'abi-exposure-audit fixture: PASS (%d checks)\n' "$checks"
