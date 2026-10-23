#!/usr/bin/env bash
set -euo pipefail

# Stock→house swap completeness: one implementation in the engine's QA
# registry (`swap-drift`, crates/gsa-qa/src/checks.rs — the port of
# build-all.fish audit_lint_swap), rendered by `gsa -Ma` and run by the
# hidden `gsa --qa-check swap-drift` seam (contract §D.1). The rule is what
# makes the install contract (`pacman -U --noconfirm --ask 4`, pinned by
# tests/install-conflict-ask.sh) actually land a swap: `--ask 4` force-YESes
# ALPM_QUESTION_CONFLICT_PKG, so the stock package IS removed — but only when
# the output CONFLICTS it, and dependents of the stock name only resolve to
# this build when it PROVIDES it. A half-declared swap (the
# qt6-xcb-private-headers class: `pkgname[1]` is a scalar inside package_*
# functions, so the arrays shipped empty) silently leaves the stock package
# installed and its dependents unresolvable.
#
# Semantics pinned here (report-only everywhere — findings never change rc):
#   * every pkgname of every committed .SRCINFO: strip a trailing
#     -git/-svn/-hg/-snapshot for the stock counterpart; when the counterpart
#     differs from the pkgname and is package-shaped (not `*.so*`), it must
#     appear in that output's EFFECTIVE provides AND conflicts;
#   * effective = the pkgbase section (makepkg merges it into every output —
#     cmake-git's shape) plus the output's own pkgname section, name-matched
#     through any `=ver`/`<ver` suffix;
#   * empty-value provides/conflicts entries are flagged outright;
#   * soname drift (the swap half of the ABI guard): a swap output's bare
#     soname provides are compared against the installed stock counterpart's
#     provides (the installed-database answer for the stripped name) and both
#     directions of the bare-stem symmetric difference are reported — a
#     surface that MOVES turns the name swap into a soname swap. Nothing
#     comparable installed (no record / no provide entries) → no drift rows.
#
# The real-repo section ratchets the known debt: the two hardened recipes
# (qt6-base-git, zlib-ng-compat-git) must stay clean and new debt fails here.
#
# Every run reads the installed database through a FABRICATED one ($tmp/db,
# a pacman local-DB `local/` tree behind a `pacman-conf DBPath` stub) — the
# battery must never depend on what the host happens to have installed (the
# abi-exposure-audit precedent: "the real pacman DB is never read"). The
# drift semantics are pinned in sections H/I against fabricated records.

# Flip notes (docs/gsa-fixture-migration.md row `tests/swap-completeness.sh`):
# argv `--audit-lint swap` flips to the hidden `gsa --qa-check swap-drift`
# seam (§D.1) and `--audit` to `gsa -Ma` (§B.7). DEVIATION (inventory target
# cell names `gsa --qa-check swap`): the engine's registry names the ported
# lint `swap-drift` (crates/gsa-qa/src/checks.rs; `gsa --qa-check` prints its
# known roster and never auto-corrects a name) — the check is the same port,
# the NAME differs; the fixture uses the registry name. The fabricated
# installed database flips from a `pacman -Qi` stub dump to the engine's
# actual reader shape (crates/gsa-install/src/localdb.rs: `<db>/local/
# <name>-<ver>/{desc,files}` behind `pacman-conf DBPath`) — which also drops
# the old stub's pass-through to the REAL pacman (`--audit`'s installed-PGO
# scan fed on host `pacman -Ql`; `-Ma` reads the same fabricated DB). Finding
# lines re-pin as §E.4 rows (`swap-drift: <subject>: <detail>`, seam) and
# `recipe-contract swap-drift: <subject> <detail>` (-Ma); the fish `swap: `
# prefix and `audit-lint swap: …` tally retire with their spellings. The
# detail sentences are the engine's — byte-identical to the fish lint's
# (a faithful port) — and the meaning pins below assert the staged DATA they
# must carry; the finding COUNTS stay derived (§L.3) from the red/green
# scenarios.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/tests/lib/fixture-lib.bash"
source "$root/tests/lib/rr-v2.bash"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-swap-completeness.XXXXXX")
trap '/usr/bin/sudo -n rm -rf -- "$tmp" 2>/dev/null || rm -rf -- "$tmp" 2>/dev/null || true' EXIT

fail() {
    printf 'swap completeness fixture: %s\n' "$1" >&2
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

# db_install DBROOT NAME VERSION [PROVIDE…] — one fabricated pacman local-DB
# entry (`<db>/local/<name>-<ver>/{desc,files}`), the shape
# crates/gsa-install/src/localdb.rs reads (docs/NOTE.md: fixtures never read
# host state).
db_install() {
    local db=$1 name=$2 version=$3
    shift 3
    local dir="$db/local/$name-$version"
    mkdir -p "$dir"
    {
        printf '%%NAME%%\n%s\n\n' "$name"
        printf '%%VERSION%%\n%s\n\n' "$version"
        printf '%%BASE%%\n%s\n' "$name"
        if [ "$#" -gt 0 ]; then
            printf '\n%%PROVIDES%%\n'
            printf '%s\n' "$@"
        fi
    } >"$dir/desc"
    printf '%%FILES%%\n' >"$dir/files"
}

# The `pacman-conf` stub answers DBPath with the fixture's fabricated root,
# never the host's /var/lib/pacman (the engine's reader falls back to it).
mkdir -p "$tmp/stub-bin"
cat >"$tmp/stub-bin/pacman-conf" <<'EOF'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = DBPath ]; then
    printf '%s\n' "${GSA_FAKE_DB_PATH:?}"
    exit 0
fi
exit 1
EOF
chmod +x "$tmp/stub-bin/pacman-conf"
export GSA_FAKE_DB_PATH="$tmp/db"
export PATH="$tmp/stub-bin:$PATH"

# lint WORKSPACE — run the swap lint through the seam into FIXTURE_OUTPUT.
lint() {
    run_engine "$1" --qa-check swap-drift
}

# ─── A. counterpart completeness: red then green ─────────────────────────────
(
    set -euo pipefail
    ws=$tmp/swap-ws
    make_workspace "$ws" 1 2 low
    add_package "$ws" foo-git
    add_package "$ws" bar-git

    # .SRCINFO shape: pkgbase/pkgname at column 0, metadata fields one tab in.
    printf 'pkgbase = foo-git\npkgname = foo-git\n' >"$ws/packages/foo-git/.SRCINFO"
    printf 'pkgbase = bar-git\npkgname = bar-git\n' >"$ws/packages/bar-git/.SRCINFO"

    lint "$ws"
    ((FIXTURE_RC == 0)) ||
        fail "A: --qa-check must stay report-only while findings exist (rc=$FIXTURE_RC)"
    grep -Fq "swap-drift: foo-git: stock counterpart 'foo' missing from provides — declare provides=('foo=\${pkgver}')" \
        <<<"$FIXTURE_OUTPUT" ||
        fail "A: missing provides finding, got: $FIXTURE_OUTPUT"
    grep -Fq "swap-drift: foo-git: stock counterpart 'foo' missing from conflicts — declare conflicts=('foo')" \
        <<<"$FIXTURE_OUTPUT" ||
        fail "A: missing conflicts finding, got: $FIXTURE_OUTPUT"
    grep -Fq "swap-drift: bar-git: stock counterpart 'bar' missing from provides" \
        <<<"$FIXTURE_OUTPUT" ||
        fail "A: every output must be checked, got: $FIXTURE_OUTPUT"
    grep -Fq 'qa-check swap-drift: 4 finding(s)' <<<"$FIXTURE_OUTPUT" ||
        fail "A: wrong finding count, got: $FIXTURE_OUTPUT"

    # Green: versioned or bare provides both match by NAME, conflicts bare.
    printf 'pkgbase = foo-git\npkgname = foo-git\n\tprovides = foo=9.9\n\tconflicts = foo\n' \
        >"$ws/packages/foo-git/.SRCINFO"
    printf 'pkgbase = bar-git\npkgname = bar-git\n\tprovides = bar\n\tconflicts = bar<2\n' \
        >"$ws/packages/bar-git/.SRCINFO"
    lint "$ws"
    ((FIXTURE_RC == 0)) || fail "A: green case failed (rc=$FIXTURE_RC)"
    grep -Fq 'qa-check swap-drift: clean' <<<"$FIXTURE_OUTPUT" ||
        fail "A: expected a clean verdict, got: $FIXTURE_OUTPUT"
    printf 'A: swap counterpart red/green OK\n'
)

# ─── B. empty provides/conflicts entries are flagged outright ────────────────
(
    set -euo pipefail
    ws=$tmp/empty-ws
    make_workspace "$ws" 1 2 low
    add_package "$ws" plain

    # 'plain' has no VCS suffix (no counterpart to swap) — the empty entries
    # must still be flagged: metadata that names nothing is never valid.
    printf 'pkgbase = plain\npkgname = plain\n\tprovides = \n\tconflicts = \n' \
        >"$ws/packages/plain/.SRCINFO"

    lint "$ws"
    ((FIXTURE_RC == 0)) || fail "B: --qa-check must stay report-only (rc=$FIXTURE_RC)"
    grep -Fq 'swap-drift: plain: empty provides entry — declare the stock counterpart or drop the entry' \
        <<<"$FIXTURE_OUTPUT" ||
        fail "B: empty provides entry not flagged, got: $FIXTURE_OUTPUT"
    grep -Fq 'swap-drift: plain: empty conflicts entry — declare the stock counterpart or drop the entry' \
        <<<"$FIXTURE_OUTPUT" ||
        fail "B: empty conflicts entry not flagged, got: $FIXTURE_OUTPUT"
    grep -Fq 'qa-check swap-drift: 2 finding(s)' <<<"$FIXTURE_OUTPUT" ||
        fail "B: empty entries must be the only findings here, got: $FIXTURE_OUTPUT"
    printf 'B: empty-entry flagging OK\n'
)

# ─── C. suffix and soname guards ─────────────────────────────────────────────
(
    set -euo pipefail
    ws=$tmp/guard-ws
    make_workspace "$ws" 1 2 low
    add_package "$ws" guards

    # One recipe, four outputs: `libfoo.so-git`'s counterpart is soname-shaped
    # (never a stock package), `bare-tool` has no suffix at all — neither may
    # produce a finding. tool-hg/tool-snapshot must be checked for the
    # stripped counterpart `tool`.
    {
        printf 'pkgbase = guards\n'
        printf 'pkgname = libfoo.so-git\n'
        printf 'pkgname = bare-tool\n'
        printf 'pkgname = tool-hg\n'
        printf 'pkgname = tool-snapshot\n'
    } >"$ws/packages/guards/.SRCINFO"

    lint "$ws"
    ((FIXTURE_RC == 0)) || fail "C: --qa-check must stay report-only (rc=$FIXTURE_RC)"
    for name in tool-hg tool-snapshot; do
        grep -Fq "swap-drift: $name: stock counterpart 'tool' missing from provides" \
            <<<"$FIXTURE_OUTPUT" ||
            fail "C: '$name' must be checked after stripping its VCS suffix, got: $FIXTURE_OUTPUT"
        grep -Fq "swap-drift: $name: stock counterpart 'tool' missing from conflicts" \
            <<<"$FIXTURE_OUTPUT" ||
            fail "C: '$name' conflicts side unchecked, got: $FIXTURE_OUTPUT"
    done
    if grep -Fq 'libfoo.so-git' <<<"$FIXTURE_OUTPUT" ||
        grep -Fq 'bare-tool' <<<"$FIXTURE_OUTPUT"; then
        fail "C: soname-shaped counterparts and suffix-less names must not be flagged: $FIXTURE_OUTPUT"
    fi
    grep -Fq 'qa-check swap-drift: 4 finding(s)' <<<"$FIXTURE_OUTPUT" ||
        fail "C: wrong finding count, got: $FIXTURE_OUTPUT"
    printf 'C: suffix/soname guards OK\n'
)

# ─── D. pkgbase-section metadata is effective for EVERY output ───────────────
(
    set -euo pipefail
    ws=$tmp/base-ws
    make_workspace "$ws" 1 2 low
    add_package "$ws" dual-git

    # cmake-git's shape: provides/conflicts render in the pkgbase section and
    # makepkg merges them into each output — they must satisfy the rule.
    printf 'pkgbase = dual-git\n\tprovides = dual=1\n\tconflicts = dual\npkgname = dual-git\n' \
        >"$ws/packages/dual-git/.SRCINFO"

    lint "$ws"
    ((FIXTURE_RC == 0)) || fail "D: green case failed (rc=$FIXTURE_RC)"
    grep -Fq 'qa-check swap-drift: clean' <<<"$FIXTURE_OUTPUT" ||
        fail "D: pkgbase-section provides/conflicts must cover every output, got: $FIXTURE_OUTPUT"
    printf 'D: pkgbase-section inheritance OK\n'
)

# ─── E. per-output scoping: sections must NOT be pooled ──────────────────────
(
    set -euo pipefail
    ws=$tmp/split-ws
    make_workspace "$ws" 1 2 low
    add_package "$ws" two-git

    # Split output: only `two-git` declares the swap metadata — `two-extra-git`
    # must still be flagged (a sibling's provides do not cover it).
    {
        printf 'pkgbase = two-git\n'
        printf 'pkgname = two-git\n'
        printf '\tprovides = two=1\n'
        printf '\tconflicts = two\n'
        printf 'pkgname = two-extra-git\n'
    } >"$ws/packages/two-git/.SRCINFO"

    lint "$ws"
    ((FIXTURE_RC == 0)) || fail "E: --qa-check must stay report-only (rc=$FIXTURE_RC)"
    grep -Fq "swap-drift: two-extra-git: stock counterpart 'two-extra' missing from provides" \
        <<<"$FIXTURE_OUTPUT" ||
        fail "E: split output must be checked on its own section, got: $FIXTURE_OUTPUT"
    grep -Fq "swap-drift: two-extra-git: stock counterpart 'two-extra' missing from conflicts" \
        <<<"$FIXTURE_OUTPUT" ||
        fail "E: split output conflicts side unchecked, got: $FIXTURE_OUTPUT"
    if grep -Fq "swap-drift: two-git:" <<<"$FIXTURE_OUTPUT"; then
        fail "E: the output that declares the swap must be clean: $FIXTURE_OUTPUT"
    fi
    grep -Fq 'qa-check swap-drift: 2 finding(s)' <<<"$FIXTURE_OUTPUT" ||
        fail "E: wrong finding count, got: $FIXTURE_OUTPUT"
    printf 'E: per-output scoping OK\n'
)

# ─── F. `gsa -Ma` renders the findings and stays report-only ────────────────
(
    set -euo pipefail
    ws=$tmp/audit-ws
    make_workspace "$ws" 1 2 low
    add_package "$ws" foo-git
    printf 'pkgbase = foo-git\npkgname = foo-git\n' >"$ws/packages/foo-git/.SRCINFO"

    run_engine "$ws" -Ma
    ((FIXTURE_RC == 0)) ||
        fail "F: -Ma must exit 0 even with findings (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    grep -Eq '^audit recipe-contract (clean|[0-9]+ finding\(s\))$' <<<"$FIXTURE_OUTPUT" ||
        fail "F: -Ma is missing the recipe-contract QA family: $FIXTURE_OUTPUT"
    grep -Fq "recipe-contract swap-drift: foo-git stock counterpart 'foo' missing from provides" \
        <<<"$FIXTURE_OUTPUT" ||
        fail "F: -Ma must render the swap findings, got: $FIXTURE_OUTPUT"
    printf 'F: -Ma integration + report-only OK\n'
)

# ─── G. real-repo gates: hardened recipes clean, debt ratcheted ──────────────
# Runs against the FABRICATED (empty) installed database: G pins the REPO's
# swap DECLARATIONS, which are host-independent — the drift half's
# installed-database semantics are pinned against fabricated RECORDS in H/I,
# never against whatever this host happens to have installed.
(
    set -euo pipefail
    run_engine "$root" --qa-check swap-drift
    ((FIXTURE_RC == 0)) || fail "G: real-repo swap lint failed (rc=$FIXTURE_RC)"

    # The two hardened recipes (qt6-base-git outputs + zlib-ng-compat-git)
    # must contribute NOTHING — their stock counterparts are fully declared.
    for name in qt6-base-git qt6-xcb-private-headers-git zlib-ng-compat-git; do
        if grep -Fq "swap-drift: $name:" <<<"$FIXTURE_OUTPUT"; then
            fail "G: hardened recipe '$name' must pass the swap lint: $FIXTURE_OUTPUT"
        fi
    done

    # Known-debt ratchet (report-only): new debt fails here; removing debt
    # shrinks the list — update this ratchet consciously; an empty list ends
    # it. The 2026-10-06 debt (niri-spicy-git's counterpart provides +
    # conflicts, vscodium-insiders-git's counterpart provide) was FIXED in
    # place, so the list is empty and the ratchet now pins it staying empty.
    { grep '^swap-drift: ' <<<"$FIXTURE_OUTPUT" || true; } | LC_ALL=C sort >"$tmp/swap.actual"
    : >"$tmp/swap.expected"
    diff -u "$tmp/swap.expected" "$tmp/swap.actual" >&2 ||
        fail 'G: the swap-lint debt set drifted — fix the recipe (declare the stock counterpart) or update this ratchet consciously'
    grep -Fq 'qa-check swap-drift: clean' <<<"$FIXTURE_OUTPUT" ||
        fail "G: expected a clean real-repo verdict, got: $FIXTURE_OUTPUT"
    printf 'G: real-repo gates OK (hardened recipes clean, debt ratchet empty)\n'
)

# ─── H. soname drift against the installed stock counterpart is reported ────
# The swap's ABI half: name-level swap COMPLETE (so only drift rows can
# appear), house carries libgreet.so + libnew.so, fabricated installed stock
# `libs` carries libgreet.so + libold.so → one row per drift direction.
(
    set -euo pipefail
    ws=$tmp/drift-ws
    make_workspace "$ws" 1 2 low
    add_package "$ws" libs-git
    {
        printf 'pkgbase = libs-git\n'
        printf 'pkgname = libs-git\n'
        printf '\tprovides = libs=1\n'
        printf '\tprovides = libgreet.so\n'
        printf '\tprovides = libnew.so\n'
        printf '\tconflicts = libs\n'
    } >"$ws/packages/libs-git/.SRCINFO"
    db_install "$tmp/db" libs 1-1 'libgreet.so=1-64' 'libold.so=0-64'
    lint "$ws"
    ((FIXTURE_RC == 0)) || fail "H: --qa-check must stay report-only (rc=$FIXTURE_RC)"
    grep -Fq "swap-drift: libs-git: soname drift vs installed stock 'libs': this recipe's provides carry 'libnew.so' that the installed stock does not" \
        <<<"$FIXTURE_OUTPUT" ||
        fail "H: house-only drift not reported, got: $FIXTURE_OUTPUT"
    grep -Fq "swap-drift: libs-git: soname drift vs installed stock 'libs': the installed stock carries 'libold.so' that this recipe's provides drop — the swap becomes a soname swap for its installed consumers" \
        <<<"$FIXTURE_OUTPUT" ||
        fail "H: stock-only drift not reported, got: $FIXTURE_OUTPUT"
    if grep -Fq 'missing from' <<<"$FIXTURE_OUTPUT"; then
        fail "H: the name-level swap is complete — only drift rows expected: $FIXTURE_OUTPUT"
    fi
    grep -Fq 'qa-check swap-drift: 2 finding(s)' <<<"$FIXTURE_OUTPUT" ||
        fail "H: wrong finding count, got: $FIXTURE_OUTPUT"
    rm -rf "$tmp/db/local/libs-1-1"
    printf 'H: soname drift reporting OK (both directions)\n'
)

# ─── I. identical soname surface → the drift finding is absent ──────────────
# Same swap shape as H, but the counterpart's auto-versioned entries
# normalize to exactly the recipe's bare stems — a drop-in swap is clean.
(
    set -euo pipefail
    ws=$tmp/match-ws
    make_workspace "$ws" 1 2 low
    add_package "$ws" libs-git
    {
        printf 'pkgbase = libs-git\n'
        printf 'pkgname = libs-git\n'
        printf '\tprovides = libs=1\n'
        printf '\tprovides = libgreet.so\n'
        printf '\tprovides = libold.so\n'
        printf '\tconflicts = libs\n'
    } >"$ws/packages/libs-git/.SRCINFO"
    db_install "$tmp/db" libs 1-1 'libgreet.so=1-64' 'libold.so=0-64'
    lint "$ws"
    ((FIXTURE_RC == 0)) || fail "I: --qa-check must stay report-only (rc=$FIXTURE_RC)"
    if grep -Fq 'soname drift' <<<"$FIXTURE_OUTPUT"; then
        fail "I: matching soname provides must not report drift: $FIXTURE_OUTPUT"
    fi
    grep -Fq 'qa-check swap-drift: clean' <<<"$FIXTURE_OUTPUT" ||
        fail "I: expected a clean verdict, got: $FIXTURE_OUTPUT"
    rm -rf "$tmp/db/local/libs-1-1"
    printf 'I: soname drift absent on matching provides OK\n'
)

printf 'swap completeness fixture: PASS (9 sections gated)\n'
