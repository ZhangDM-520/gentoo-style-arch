#!/usr/bin/env bash
set -euo pipefail

# Recipe-contract lints: provides versioning, the purged-tools denylist and
# the IgnorePkg closure. One implementation per rule lives in build-all.fish
# (audit_lint_provides / audit_lint_purged / audit_lint_ignorepkg);
# `fish build-all.fish --audit` renders them in its report and the hidden
# `--audit-lint <name> [pacman-conf]` seam runs one of them — the seam is the
# interface, and this fixture is its gating walker (red/green per rule, then
# the real-repo gates).
#
# Enforcement mapping (the settled three-tier rule):
#   deterministic + must-gate  provides-versioning, purged-tools → --audit
#                              lints, GATED here (fixture rc, never --audit's);
#   host-state                 IgnorePkg closure → --audit lint (report-only,
#                              Q20) + gate here that reads /etc/pacman.conf
#                              DIRECTLY and skips only when it is unreadable
#                              (Q17); the cumulative [options] semantics are
#                              proven against scratch confs through the seam's
#                              path argument;
#   heavy/ELF                  soname-presence → tools/provides-audit.sh pair.
# PGP procedure and trimming stay docs-only by the same mapping.
#
# Every scratch workspace and conf lives under $TMPDIR; the real-repo sections
# are read-only.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/tests/lib/fixture-lib.bash"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-recipe-contract.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    printf 'recipe contract fixture: %s\n' "$1" >&2
    exit 1
}

# lint WORKSPACE NAME [CONF] — run one audit lint through the seam.
lint() {
    local ws=$1 name=$2 conf=${3:-}
    if [[ -n $conf ]]; then
        run_builder fish "$ws/build-all.fish" --audit-lint "$name" "$conf"
    else
        run_builder fish "$ws/build-all.fish" --audit-lint "$name"
    fi
}

# write_srcinfo DIR BASE [EXTRA_PKGNAME...] — committed-.SRCINFO shape:
# pkgbase/pkgname at column 0, metadata fields one tab in. Callers append
# their fields with `printf '\tfield = value\n' >>"$DIR/.SRCINFO"`.
write_srcinfo() {
    local dir=$1 base=$2
    shift 2
    {
        printf 'pkgbase = %s\n' "$base"
        printf 'pkgname = %s\n' "$base"
        local name
        for name in "$@"; do
            [[ $name == "$base" ]] && continue
            printf 'pkgname = %s\n' "$name"
        done
    } >"$dir/.SRCINFO"
}

# ─── A. provides versioning: red/green through the seam ──────────────────────
(
    set -euo pipefail
    ws=$tmp/provides-ws
    make_workspace "$ws" 1 2 low
    add_package "$ws" prov-git
    add_package "$ws" consumer-git
    add_package "$ws" libs-git

    # P1 mechanism: an unversioned provide cannot satisfy a versioned
    # constraint, so pacman falls back to the repo package (the meson class).
    write_srcinfo "$ws/packages/prov-git" prov-git
    printf '\tprovides = meson\n' >>"$ws/packages/prov-git/.SRCINFO"
    write_srcinfo "$ws/packages/consumer-git" consumer-git
    printf '\tmakedepends = meson>=1.8\n' >>"$ws/packages/consumer-git/.SRCINFO"
    write_srcinfo "$ws/packages/libs-git" libs-git

    lint "$ws" provides
    if ((FIXTURE_RC != 0)); then
        fail "A: --audit-lint must stay report-only while findings exist (rc=$FIXTURE_RC)"
    fi
    grep -Fq "provides: prov-git: unversioned provide 'meson' cannot satisfy 'meson>=1.8' (required by consumer-git) — version it as provides=('meson=\${pkgver}')" \
        <<<"$FIXTURE_OUTPUT" ||
        fail "A: missing or wrong P1 finding, got: $FIXTURE_OUTPUT"

    # P2/P3 soname forms, plus the BARE stem that must NOT be flagged.
    printf '\tprovides = libfoo.so=2-64\n' >>"$ws/packages/libs-git/.SRCINFO"
    printf '\tprovides = libbar.so.1\n' >>"$ws/packages/libs-git/.SRCINFO"
    printf '\tprovides = libbaz.so\n' >>"$ws/packages/libs-git/.SRCINFO"
    lint "$ws" provides
    grep -Fq "provides: libs-git: soname provide 'libfoo.so=2-64' is hand-versioned — declare the bare stem 'libfoo.so' and let makepkg auto-version it from the built ELF" \
        <<<"$FIXTURE_OUTPUT" ||
        fail "A: missing P2 finding, got: $FIXTURE_OUTPUT"
    grep -Fq "provides: libs-git: soname provide 'libbar.so.1' names a versioned soname — declare the bare stem 'libbar.so'" \
        <<<"$FIXTURE_OUTPUT" ||
        fail "A: missing P3 finding, got: $FIXTURE_OUTPUT"
    grep -Fq 'libbaz.so' <<<"$FIXTURE_OUTPUT" &&
        fail "A: a bare soname stem is the correct form and must not be flagged: $FIXTURE_OUTPUT"
    grep -Fq 'audit-lint provides: 3 finding(s)' <<<"$FIXTURE_OUTPUT" ||
        fail "A: wrong finding count, got: $FIXTURE_OUTPUT"

    # Green: versioned provide for the constrained name, bare soname stems.
    write_srcinfo "$ws/packages/prov-git" prov-git
    printf '\tprovides = meson=1.8.0\n' >>"$ws/packages/prov-git/.SRCINFO"
    write_srcinfo "$ws/packages/libs-git" libs-git
    printf '\tprovides = libbaz.so\n' >>"$ws/packages/libs-git/.SRCINFO"
    lint "$ws" provides
    ((FIXTURE_RC == 0)) || fail "A: green case failed (rc=$FIXTURE_RC)"
    grep -Fq 'audit-lint provides: clean' <<<"$FIXTURE_OUTPUT" ||
        fail "A: expected a clean verdict, got: $FIXTURE_OUTPUT"
    printf 'A: provides versioning red/green OK\n'
)

# ─── B. purged-tools denylist: red/green through the seam ────────────────────
(
    set -euo pipefail
    ws=$tmp/purged-ws
    make_workspace "$ws" 1 2 low
    add_package "$ws" tools-git

    # Exact-name denylist: 'python-sphinx-theme' must NOT match
    # 'python-sphinx', and checkdepends is a build-time install vector just
    # like makedepends (makepkg installs both silently).
    write_srcinfo "$ws/packages/tools-git" tools-git
    printf '\tmakedepends = python-sphinx\n' >>"$ws/packages/tools-git/.SRCINFO"
    printf '\tmakedepends = python-sphinx-theme\n' >>"$ws/packages/tools-git/.SRCINFO"
    printf '\tcheckdepends = po4a>=0.6\n' >>"$ws/packages/tools-git/.SRCINFO"
    lint "$ws" purged
    ((FIXTURE_RC == 0)) || fail "B: --audit-lint must stay report-only (rc=$FIXTURE_RC)"
    grep -Fq "purged: tools-git: makedepends reintroduces purged tool 'python-sphinx' — remove it (docs/MEMORY.md rule 8)" \
        <<<"$FIXTURE_OUTPUT" ||
        fail "B: missing makedepends finding, got: $FIXTURE_OUTPUT"
    grep -Fq "purged: tools-git: checkdepends reintroduces purged tool 'po4a' — remove it (docs/MEMORY.md rule 8)" \
        <<<"$FIXTURE_OUTPUT" ||
        fail "B: missing checkdepends finding, got: $FIXTURE_OUTPUT"
    grep -Fq 'audit-lint purged: 2 finding(s)' <<<"$FIXTURE_OUTPUT" ||
        fail "B: the denylist must match exact names only (count != 2): $FIXTURE_OUTPUT"

    write_srcinfo "$ws/packages/tools-git" tools-git
    printf '\tmakedepends = python-sphinx-theme\n' >>"$ws/packages/tools-git/.SRCINFO"
    lint "$ws" purged
    grep -Fq 'audit-lint purged: clean' <<<"$FIXTURE_OUTPUT" ||
        fail "B: expected a clean verdict, got: $FIXTURE_OUTPUT"
    printf 'B: purged-tools denylist red/green OK\n'
)

# ─── C. IgnorePkg closure: pacman.conf semantics + Q17 skip ──────────────────
(
    set -euo pipefail
    ws=$tmp/ignorepkg-ws
    make_workspace "$ws" 1 2 low
    add_package "$ws" p1
    add_package "$ws" q
    write_srcinfo "$ws/packages/p1" p1
    write_srcinfo "$ws/packages/q" q q-libs # split output: two names under test

    conf_ok=$tmp/conf-ok
    cat >"$conf_ok" <<EOF
# Repeated IgnorePkg lines inside [options] ACCUMULATE (Q16 semantics), and a
# repo section's IgnorePkg line is silently dropped.
[options]
IgnorePkg = p1
IgnorePkg = q   q-libs

[cachyos]
Include = /etc/pacman.d/cachyos-mirrorlist
IgnorePkg = decoy-repo-section
EOF
    lint "$ws" ignorepkg "$conf_ok"
    ((FIXTURE_RC == 0)) || fail "C: clean case failed (rc=$FIXTURE_RC)"
    grep -Fq 'audit-lint ignorepkg: clean' <<<"$FIXTURE_OUTPUT" ||
        fail "C: cumulative [options] lines must cover every name, got: $FIXTURE_OUTPUT"

    # Drop conf: the pre-header line belongs to no section, the [core] line is
    # repo-scoped, and a commented line is not a directive — all three names
    # must come back as findings.
    conf_drop=$tmp/conf-drop
    cat >"$conf_drop" <<EOF
IgnorePkg = p1
[core]
IgnorePkg = q q-libs
[options]
# IgnorePkg = q
EOF
    lint "$ws" ignorepkg "$conf_drop"
    ((FIXTURE_RC == 0)) || fail "C: --audit-lint must stay report-only (rc=$FIXTURE_RC)"
    for name in p1 q q-libs; do
        grep -Fq "ignorepkg: $name is not in the IgnorePkg closure of $conf_drop" \
            <<<"$FIXTURE_OUTPUT" ||
            fail "C: '$name' must be reported when its only IgnorePkg line is dropped, got: $FIXTURE_OUTPUT"
    done
    grep -Fq 'audit-lint ignorepkg: 3 finding(s)' <<<"$FIXTURE_OUTPUT" ||
        fail "C: wrong finding count (comment/pre-header/repo lines must not count): $FIXTURE_OUTPUT"

    # Inline comments strip after the names; the names before '#' still count.
    conf_comment=$tmp/conf-comment
    cat >"$conf_comment" <<EOF
[options]
IgnorePkg = p1 # trailing comment
IgnorePkg = q q-libs
EOF
    lint "$ws" ignorepkg "$conf_comment"
    grep -Fq 'audit-lint ignorepkg: clean' <<<"$FIXTURE_OUTPUT" ||
        fail "C: inline comments must strip after the names, got: $FIXTURE_OUTPUT"

    # An [options] Include cannot be followed here: report it instead of
    # silently under-counting the closure.
    conf_include=$tmp/conf-include
    cat >"$conf_include" <<EOF
[options]
Include = $tmp/extra.conf
IgnorePkg = p1 q q-libs
EOF
    lint "$ws" ignorepkg "$conf_include"
    grep -Fq "ignorepkg: $conf_include: [options] Include is not followed — inline its IgnorePkg entries into the file" \
        <<<"$FIXTURE_OUTPUT" ||
        fail "C: an [options] Include must be reported, got: $FIXTURE_OUTPUT"
    grep -Fq 'audit-lint ignorepkg: 1 finding(s)' <<<"$FIXTURE_OUTPUT" ||
        fail "C: the Include finding must be the only one when all names are covered, got: $FIXTURE_OUTPUT"

    # Q17: the ONLY skip condition is an unreadable conf — and it says so.
    lint "$ws" ignorepkg "$tmp/no-such.conf"
    ((FIXTURE_RC == 0)) || fail "C: skip must stay report-only (rc=$FIXTURE_RC)"
    grep -Fq "ignorepkg: skipped — $tmp/no-such.conf is not readable" <<<"$FIXTURE_OUTPUT" ||
        fail "C: skip must name the unreadable conf, got: $FIXTURE_OUTPUT"
    grep -Fq 'audit-lint ignorepkg: skipped' <<<"$FIXTURE_OUTPUT" ||
        fail "C: skip must be visible in the verdict line, got: $FIXTURE_OUTPUT"
    printf 'C: IgnorePkg semantics + skip OK\n'
)

# ─── D. --audit renders the lints and stays report-only (Q20) ────────────────
(
    set -euo pipefail
    ws=$tmp/audit-ws
    make_workspace "$ws" 1 2 low
    add_package "$ws" prov-git
    write_srcinfo "$ws/packages/prov-git" prov-git
    printf '\tprovides = libfoo.so=2-64\n' >>"$ws/packages/prov-git/.SRCINFO"

    run_builder fish "$ws/build-all.fish" --audit
    ((FIXTURE_RC == 0)) ||
        fail "D: --audit must exit 0 even with findings (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    for heading in 'Provides versioning:' 'Purged tools:' 'IgnorePkg closure:'; do
        grep -Fq "$heading" <<<"$FIXTURE_OUTPUT" ||
            fail "D: --audit is missing the '$heading' section: $FIXTURE_OUTPUT"
    done
    grep -Fq 'provides: prov-git: soname provide' <<<"$FIXTURE_OUTPUT" ||
        fail "D: --audit must render the lint findings, got: $FIXTURE_OUTPUT"
    printf 'D: --audit integration + report-only OK\n'
)

# ─── E. real-repo gates ──────────────────────────────────────────────────────
(
    set -euo pipefail
    run_builder fish "$root/build-all.fish" --audit-lint provides
    ((FIXTURE_RC == 0)) || fail "E: real-repo provides lint failed (rc=$FIXTURE_RC)"

    # P2 debt cleared 2026-10-04: the list is empty and stays a strict gate —
    # any NEW hand-pinned soname provide fails here (bare-declare the stem).
    # P1/P3 must be empty too: all provides findings are forbidden now.
    sed -n "s/^provides: \([^:]*\): soname provide '\([^']*\)' is hand-versioned .*/\1: \2/p" \
        <<<"$FIXTURE_OUTPUT" | LC_ALL=C sort >"$tmp/p2.actual"
    if grep '^provides: ' <<<"$FIXTURE_OUTPUT" |
        grep -v ' is hand-versioned — ' | grep -q .; then
        fail "E: non-P2 provides finding on the real repo (P1/P3 must be empty): $FIXTURE_OUTPUT"
    fi
    cat >"$tmp/p2.expected" <<'EOF'
EOF
    LC_ALL=C sort -o "$tmp/p2.expected" "$tmp/p2.expected"
    diff -u "$tmp/p2.expected" "$tmp/p2.actual" >&2 ||
        fail 'E: the hand-pinned soname-provides set drifted — fix the recipe (bare-declare the stem) or update this ratchet consciously'

    run_builder fish "$root/build-all.fish" --audit-lint purged
    ((FIXTURE_RC == 0)) || fail "E: real-repo purged lint failed (rc=$FIXTURE_RC)"
    grep -Fq 'audit-lint purged: clean' <<<"$FIXTURE_OUTPUT" ||
        fail "E: a purged tool re-entered the workspace: $FIXTURE_OUTPUT"

    run_builder fish "$root/build-all.fish" --audit-lint ignorepkg
    ((FIXTURE_RC == 0)) || fail "E: real-repo ignorepkg lint failed (rc=$FIXTURE_RC)"
    if [[ -r /etc/pacman.conf ]]; then
        grep -Fq 'audit-lint ignorepkg: clean' <<<"$FIXTURE_OUTPUT" ||
            fail "E: a workspace pkgname is missing from the IgnorePkg closure: $FIXTURE_OUTPUT"
    else
        # Q17: the gate skips exactly here, and says so.
        grep -Fq "ignorepkg: skipped — /etc/pacman.conf is not readable" <<<"$FIXTURE_OUTPUT" ||
            fail "E: unreadable /etc/pacman.conf must produce the skip line, got: $FIXTURE_OUTPUT"
    fi
    printf 'E: real-repo gates OK\n'
)

printf 'recipe contract fixture: PASS (3 lint seams gated, real-repo gates green)\n'
