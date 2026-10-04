#!/usr/bin/env bash
set -euo pipefail

# Stock→house swap completeness: one implementation in build-all.fish
# (audit_lint_swap), rendered by `--audit` and run by the hidden
# `--audit-lint swap` seam. The rule is what makes the -i install contract
# (`pacman -U --noconfirm --ask 4`, pinned by tests/install-conflict-ask.sh)
# actually land a swap: `--ask 4` force-YESes ALPM_QUESTION_CONFLICT_PKG, so
# the stock package IS removed — but only when the output CONFLICTS it, and
# dependents of the stock name only resolve to this build when it PROVIDES it.
# A half-declared swap (the qt6-xcb-private-headers class: `pkgname[1]` is a
# scalar inside package_* functions, so the arrays shipped empty) silently
# leaves the stock package installed and its dependents unresolvable.
#
# Semantics pinned here (report-only everywhere — findings never change rc):
#   * every pkgname of every committed .SRCINFO: strip a trailing
#     -git/-svn/-hg/-snapshot for the stock counterpart; when the counterpart
#     differs from the pkgname and is package-shaped (not `*.so*`), it must
#     appear in that output's EFFECTIVE provides AND conflicts;
#   * effective = the pkgbase section (makepkg merges it into every output —
#     cmake-git's shape) plus the output's own pkgname section, name-matched
#     through any `=ver`/`<ver` suffix;
#   * empty-value provides/conflicts entries are flagged outright.
#
# The real-repo section ratchets the known debt: the two hardened recipes
# (qt6-base-git, zlib-ng-compat-git) must stay clean and new debt fails here.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/tests/lib/fixture-lib.bash"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-swap-completeness.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    printf 'swap completeness fixture: %s\n' "$1" >&2
    exit 1
}

# lint WORKSPACE — run the swap lint through the seam into FIXTURE_OUTPUT.
lint() {
    run_builder fish "$1/build-all.fish" --audit-lint swap
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
        fail "A: --audit-lint must stay report-only while findings exist (rc=$FIXTURE_RC)"
    grep -Fq "swap: foo-git: stock counterpart 'foo' missing from provides — declare provides=('foo=\${pkgver}')" \
        <<<"$FIXTURE_OUTPUT" ||
        fail "A: missing provides finding, got: $FIXTURE_OUTPUT"
    grep -Fq "swap: foo-git: stock counterpart 'foo' missing from conflicts — declare conflicts=('foo')" \
        <<<"$FIXTURE_OUTPUT" ||
        fail "A: missing conflicts finding, got: $FIXTURE_OUTPUT"
    grep -Fq "swap: bar-git: stock counterpart 'bar' missing from provides" \
        <<<"$FIXTURE_OUTPUT" ||
        fail "A: every output must be checked, got: $FIXTURE_OUTPUT"
    grep -Fq 'audit-lint swap: 4 finding(s)' <<<"$FIXTURE_OUTPUT" ||
        fail "A: wrong finding count, got: $FIXTURE_OUTPUT"

    # Green: versioned or bare provides both match by NAME, conflicts bare.
    printf 'pkgbase = foo-git\npkgname = foo-git\n\tprovides = foo=9.9\n\tconflicts = foo\n' \
        >"$ws/packages/foo-git/.SRCINFO"
    printf 'pkgbase = bar-git\npkgname = bar-git\n\tprovides = bar\n\tconflicts = bar<2\n' \
        >"$ws/packages/bar-git/.SRCINFO"
    lint "$ws"
    ((FIXTURE_RC == 0)) || fail "A: green case failed (rc=$FIXTURE_RC)"
    grep -Fq 'audit-lint swap: clean' <<<"$FIXTURE_OUTPUT" ||
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
    ((FIXTURE_RC == 0)) || fail "B: --audit-lint must stay report-only (rc=$FIXTURE_RC)"
    grep -Fq 'swap: plain: empty provides entry — declare the stock counterpart or drop the entry' \
        <<<"$FIXTURE_OUTPUT" ||
        fail "B: empty provides entry not flagged, got: $FIXTURE_OUTPUT"
    grep -Fq 'swap: plain: empty conflicts entry — declare the stock counterpart or drop the entry' \
        <<<"$FIXTURE_OUTPUT" ||
        fail "B: empty conflicts entry not flagged, got: $FIXTURE_OUTPUT"
    grep -Fq 'audit-lint swap: 2 finding(s)' <<<"$FIXTURE_OUTPUT" ||
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
    ((FIXTURE_RC == 0)) || fail "C: --audit-lint must stay report-only (rc=$FIXTURE_RC)"
    for name in tool-hg tool-snapshot; do
        grep -Fq "swap: $name: stock counterpart 'tool' missing from provides" \
            <<<"$FIXTURE_OUTPUT" ||
            fail "C: '$name' must be checked after stripping its VCS suffix, got: $FIXTURE_OUTPUT"
        grep -Fq "swap: $name: stock counterpart 'tool' missing from conflicts" \
            <<<"$FIXTURE_OUTPUT" ||
            fail "C: '$name' conflicts side unchecked, got: $FIXTURE_OUTPUT"
    done
    if grep -Fq 'libfoo.so-git' <<<"$FIXTURE_OUTPUT" ||
        grep -Fq 'bare-tool' <<<"$FIXTURE_OUTPUT"; then
        fail "C: soname-shaped counterparts and suffix-less names must not be flagged: $FIXTURE_OUTPUT"
    fi
    grep -Fq 'audit-lint swap: 4 finding(s)' <<<"$FIXTURE_OUTPUT" ||
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
    grep -Fq 'audit-lint swap: clean' <<<"$FIXTURE_OUTPUT" ||
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
    ((FIXTURE_RC == 0)) || fail "E: --audit-lint must stay report-only (rc=$FIXTURE_RC)"
    grep -Fq "swap: two-extra-git: stock counterpart 'two-extra' missing from provides" \
        <<<"$FIXTURE_OUTPUT" ||
        fail "E: split output must be checked on its own section, got: $FIXTURE_OUTPUT"
    grep -Fq "swap: two-extra-git: stock counterpart 'two-extra' missing from conflicts" \
        <<<"$FIXTURE_OUTPUT" ||
        fail "E: split output conflicts side unchecked, got: $FIXTURE_OUTPUT"
    if grep -Fq "swap: two-git:" <<<"$FIXTURE_OUTPUT"; then
        fail "E: the output that declares the swap must be clean: $FIXTURE_OUTPUT"
    fi
    grep -Fq 'audit-lint swap: 2 finding(s)' <<<"$FIXTURE_OUTPUT" ||
        fail "E: wrong finding count, got: $FIXTURE_OUTPUT"
    printf 'E: per-output scoping OK\n'
)

# ─── F. --audit renders the block and stays report-only ──────────────────────
(
    set -euo pipefail
    ws=$tmp/audit-ws
    make_workspace "$ws" 1 2 low
    add_package "$ws" foo-git
    printf 'pkgbase = foo-git\npkgname = foo-git\n' >"$ws/packages/foo-git/.SRCINFO"

    run_builder fish "$ws/build-all.fish" --audit
    ((FIXTURE_RC == 0)) ||
        fail "F: --audit must exit 0 even with findings (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    grep -Fq 'Stock→house swap:' <<<"$FIXTURE_OUTPUT" ||
        fail "F: --audit is missing the swap section: $FIXTURE_OUTPUT"
    grep -Fq "swap: foo-git: stock counterpart 'foo' missing from provides" \
        <<<"$FIXTURE_OUTPUT" ||
        fail "F: --audit must render the swap findings, got: $FIXTURE_OUTPUT"
    printf 'F: --audit integration + report-only OK\n'
)

# ─── G. real-repo gates: hardened recipes clean, debt ratcheted ──────────────
(
    set -euo pipefail
    run_builder fish "$root/build-all.fish" --audit-lint swap
    ((FIXTURE_RC == 0)) || fail "G: real-repo swap lint failed (rc=$FIXTURE_RC)"

    # The two hardened recipes (qt6-base-git outputs + zlib-ng-compat-git)
    # must contribute NOTHING — their stock counterparts are fully declared.
    for name in qt6-base-git qt6-xcb-private-headers-git zlib-ng-compat-git; do
        if grep -Fq "swap: $name:" <<<"$FIXTURE_OUTPUT"; then
            fail "G: hardened recipe '$name' must pass the swap lint: $FIXTURE_OUTPUT"
        fi
    done

    # Known-debt ratchet (report-only, 2 recipes outside the hardening change):
    # new debt fails here; removing debt shrinks the list — update this
    # ratchet consciously; an empty list ends it.
    { grep '^swap: ' <<<"$FIXTURE_OUTPUT" || true; } | LC_ALL=C sort >"$tmp/swap.actual"
    cat >"$tmp/swap.expected" <<'EOF'
swap: niri-spicy-git: stock counterpart 'niri-spicy' missing from provides — declare provides=('niri-spicy=${pkgver}')
swap: niri-spicy-git: stock counterpart 'niri-spicy' missing from conflicts — declare conflicts=('niri-spicy')
swap: vscodium-insiders-git: stock counterpart 'vscodium-insiders' missing from provides — declare provides=('vscodium-insiders=${pkgver}')
EOF
    LC_ALL=C sort -o "$tmp/swap.expected" "$tmp/swap.expected"
    diff -u "$tmp/swap.expected" "$tmp/swap.actual" >&2 ||
        fail 'G: the swap-lint debt set drifted — fix the recipe (declare the stock counterpart) or update this ratchet consciously'
    grep -Fq 'audit-lint swap: 3 finding(s)' <<<"$FIXTURE_OUTPUT" ||
        fail "G: wrong real-repo finding count, got: $FIXTURE_OUTPUT"
    printf 'G: real-repo gates OK (hardened recipes clean, 2-recipe debt ratchet)\n'
)

printf 'swap completeness fixture: PASS (7 sections gated)\n'
