#!/usr/bin/env bash
set -euo pipefail

# tests/gsa-qa-v2.sh — the QA check REGISTRY of the native engine (`gsa`,
# docs/gsa-contract.md §D.1 `--qa-check` / §E.4 QA gate line / §G rc
# classes). Everything here is synthetic: $TMPDIR workspaces, fabricated
# pacman local databases, and stub `makepkg`/`sudo`/`pacman`/`pacman-conf`
# executables — no transaction ever reaches the host. Expectations are
# DERIVED: decision and outcome rows come from the machine run record the run
# produced (rule 25(j) / contract §L.3), and the QA findings are the ones
# this fixture staged into the committed `.SRCINFO`/archive bytes.
#
# Pinned here (four ( subshell ) sections, one per scenario; run one alone
# with GSA_QA_V2_ONLY=a…d):
#   a. the named-check seam (`gsa --qa-check <name> [ref…]`, §D.1) runs ONE
#      check and prints its findings: `report` findings with rc 0 (the
#      report-only promise from the seam's side), the loud `skipped — …`
#      class, the recipe-reference focus filter, and the stable
#      `<check>: <subject>: <detail>` framing + `qa-check <name>: …` tally.
#   b. report-only ENFORCEMENT: a lint finding never changes the install
#      decision — `--install-decide` rows are `install`/`skip` only (§E.5
#      rc 0), the `-U` run transacts normally, and the findings appear
#      solely as the prose-summary QA block (additive; the §H.2 choice:
#      no machine rows, `format: 2` untouched).
#   c. an install-refusing check (stale-ignorepkg) emits `refuse` rows with
#      its stable keyword first (§E.3) at the ONE decision seam: the
#      `--install-decide` seam refuses (rc 1, §E.5) and the `-U` run is the
#      rc 3 refusal class (§G.1) with ZERO pacman/sudo calls and the
#      IgnorePkg conf byte-identical (rule 25(h): pacman-free end to end);
#      through `--qa-check` the same finding is the rc 3 class too.
#   d. unknown check name / missing name / unknown recipe reference are the
#      usage class (rc 2, §G) with the known roster named — a keyword is
#      never auto-corrected.
#
# House conventions: `( subshell )` sections (each an isolated scenario with
# its own workspace), inline oracle stubs (§D.2), `fail()` prefixes, and
# tests/lib/rr-v2.bash's run_engine with GSA_TEST_ENGINE=gsa. `-U` run
# records render `lanes: -` and one plan row per DECISION row, so rr2_*
# (strict: integer budget scalars) cannot read them — those sections extract
# record fields inline and say so. No new GSA_FAKE_* knobs: the stubs use the
# existing GSA_FAKE_PACMAN_LOG / GSA_FAKE_SUDO_LOG vocabulary.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"

fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-qa-v2.XXXXXX")
# Root-safe cleanup: a privileged -U run leaves ROOT-owned state behind (§B.10
# — engine-side state is root-owned), so the EXIT trap escalates first through
# the ABSOLUTE /usr/bin/sudo (never the PATH stub).
trap '/usr/bin/sudo -n rm -rf -- "$fixture" 2>/dev/null || rm -rf -- "$fixture" 2>/dev/null || true' EXIT

fail() {
    printf '%s\n' "$1" >&2
    if [ -n "${2:-}" ] && [ -f "$2" ]; then
        sed 's/^/    /' "$2" >&2
    fi
    # Always show the engine output the assertions just checked: many call
    # sites pass "$FIXTURE_OUTPUT" as $2 (text, not a file), so without this
    # a battery failure prints no captured output at all.
    if [ -n "${FIXTURE_OUTPUT:-}" ]; then
        printf '%s\n' '--- captured engine output ---' >&2
        printf '%s\n' "$FIXTURE_OUTPUT" >&2
    fi
    exit 1
}

# Section filter: GSA_QA_V2_ONLY=<a..d> runs exactly one section.
want() { [ -z "${GSA_QA_V2_ONLY:-}" ] || [ "${GSA_QA_V2_ONLY}" = "$1" ]; }

# ─── The engine under test: built into the fixture tree (scratch only).
# GSA_TEST_GSA_BIN, when already set to an executable, is that engine (the
# rr-v2.bash run_engine convention) and the scratch build is skipped. ──────
if [ -z "${GSA_TEST_GSA_BIN:-}" ]; then
    cargo build --offline --quiet --target-dir "$fixture/cargo" -p gsa-cli \
        --manifest-path "$gsa_repo_root/Cargo.toml" \
        || fail "cannot build the gsa binary for the fixture"
    GSA_TEST_GSA_BIN="$fixture/cargo/debug/gsa"
fi
[ -x "$GSA_TEST_GSA_BIN" ] || fail "the engine under test is not executable: $GSA_TEST_GSA_BIN"
export GSA_TEST_ENGINE=gsa
export GSA_TEST_GSA_BIN

# ─── Oracle stubs and staging helpers (inline: §D.2 keeps oracles in the
# fixture that gives them meaning) ─────────────────────────────────────────

# write_stub_pacman DIR — the transaction oracle: one argv line per
# invocation; the zero-call assertions read its log.
write_stub_pacman() {
    cat >"$1/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'pacman %s\n' "$*" >>"${GSA_FAKE_PACMAN_LOG:?}"
exit 0
EOF
    chmod +x "$1/bin/pacman"
}

# write_stub_sudo DIR — the sudo passthrough with an argv log: the refusal
# sections assert it is never reached.
write_stub_sudo() {
    cat >"$1/bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'sudo %s\n' "$*" >>"${GSA_FAKE_SUDO_LOG:?}"
args=()
for a in "$@"; do
    case $a in
    -n | -v | --preserve-env | --preserve-env=* | --) ;;
    *) args+=("$a") ;;
    esac
done
((${#args[@]})) || exit 0
exec "${args[@]}"
EOF
    chmod +x "$1/bin/sudo"
}

# write_stub_pacman_conf DIR DBROOT — `pacman-conf DBPath` answers the
# fixture's fabricated DB root, never the host's (§D.1 stays pacman-free).
write_stub_pacman_conf() {
    cat >"$1/bin/pacman-conf" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = DBPath ] && printf '%s\n' "$2"
exit 0
EOF
    chmod +x "$1/bin/pacman-conf"
}

# qa_ws DIR DBROOT — one workspace with the three stubs on PATH and the
# fixture's fabricated DB wired in.
qa_ws() {
    local ws=$1 db=$2
    write_stub_pacman "$ws"
    write_stub_sudo "$ws"
    write_stub_pacman_conf "$ws" "$db"
    export PATH="$ws/bin:$PATH"
    export GSA_FAKE_PACMAN_LOG="$ws/pacman.log"
    export GSA_FAKE_SUDO_LOG="$ws/sudo.log"
    : >"$GSA_FAKE_PACMAN_LOG"
    : >"$GSA_FAKE_SUDO_LOG"
    mkdir -p "$db"
}

# write_srcinfo DIR ID BODY — the recipe's committed `.SRCINFO` (verbatim
# body; the QA checks' ONLY recipe input — a PKGBUILD is never evaluated).
write_srcinfo() {
    printf '%s\n' "$3" >"$1/packages/$2/.SRCINFO"
}

# stage_archive DIR RECIPE PKGBASE PKGNAME [PKGLINE…] — one hand-built
# `.pkg.tar.zst` beside its recipe (`.PKGINFO` truth, optionally extra
# `key = value` lines).
stage_archive() {
    local ws=$1 recipe=$2 base=$3 name=$4
    shift 4
    local stage="$ws/.stage-$name"
    mkdir -p "$stage"
    {
        printf 'pkgbase = %s\n' "$base"
        printf 'pkgname = %s\n' "$name"
        printf 'pkgver = 1.0.0-1\n'
        printf 'arch = any\n'
        if [ "$#" -gt 0 ]; then
            printf '%s\n' "$@"
        fi
    } >"$stage/.PKGINFO"
    tar --zstd -cf "$ws/packages/$recipe/$name-1.0.0-1-any.pkg.tar.zst" -C "$stage" .PKGINFO
    rm -rf -- "$stage"
}

# db_install DBROOT NAME FULL-VERSION [PROVIDE…] — one fabricated pacman
# local-DB entry; the entry directory's mtime IS the install date.
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

# record_scalar KEY — one scalar of the machine block of a capture (the -U
# record sections parse inline: rr2_* rejects their `lanes: -`).
record_scalar() {
    printf '%s\n' "$FIXTURE_OUTPUT" | sed -n '/^--- run record begin ---$/,/^--- run record end ---$/p' \
        | sed -n "s/^$1: //p" | head -n 1
}

# record_section plan|outcome — one section's rows of the machine block.
record_section() {
    printf '%s\n' "$FIXTURE_OUTPUT" | sed -n '/^--- run record begin ---$/,/^--- run record end ---$/p' \
        | awk -v sec="$1" '
            $0 == "--- " sec " ---" { p = 1; next }
            /^--- / { p = 0 }
            p { print }'
}

# decision_rows — the §E.2 decision rows of a capture (rows come before any
# prose/record span).
decision_rows() {
    awk '
        /^--- run record begin ---/ || /^Build run: / { exit }
        /^[A-Za-z0-9@._+-]+ (install|skip|refuse|noop|parked) / { print }
    ' <<<"$FIXTURE_OUTPUT"
}

# qa_lines — the prose QA block's finding lines of a capture.
qa_lines() {
    awk '/^· / && seen { print } /^QA report \(report-only\)/ { seen = 1 }' <<<"$FIXTURE_OUTPUT"
}

if want a; then
    # ─── a. the named-check seam: one check, its findings, rc per §G ──────
    (
        set -euo pipefail
        ws="$fixture/a/ws"
        db="$fixture/a/db"
        make_workspace "$ws" 1 auto low
        qa_ws "$ws" "$db"

        # viol breaks the two recipe-scope lints; kit-git breaks the swap
        # rule (a VCS-suffixed output with no stock counterpart declared);
        # clean breaks nothing.
        add_package "$ws" viol "$gsa_meta_any"
        add_package "$ws" kit-git "$gsa_meta_any"
        add_package "$ws" clean "$gsa_meta_any"
        write_srcinfo "$ws" viol "pkgbase = viol
	pkgver = 1.0.0
	pkgrel = 1
	arch = any
	provides = libx.so.1
	makedepends = cuda
pkgname = viol"
        write_srcinfo "$ws" kit-git "pkgbase = kit-git
	pkgver = 1.0.0
	pkgrel = 1
	arch = any
pkgname = kit-git"
        write_srcinfo "$ws" clean "pkgbase = clean
	pkgver = 1.0.0
	pkgrel = 1
	arch = any
pkgname = clean"

        # purged-tools: one finding for the staged tool (derived from the
        # staged makedepends), rc 0 — report findings never change rc.
        run_engine "$ws" --qa-check purged-tools
        [ "$FIXTURE_RC" = 0 ] || fail "a report check is rc 0 (§G), got $FIXTURE_RC: $FIXTURE_OUTPUT"
        vgrep "$FIXTURE_OUTPUT" -Fqx \
            "purged-tools: viol: makedepends reintroduces purged tool 'cuda' — remove it (docs/MEMORY.md rule 8)" \
            || fail "the staged purged tool must be named verbatim:" "$fixture/a/out"
        vgrep "$FIXTURE_OUTPUT" -Fqx "qa-check purged-tools: 1 finding(s)" \
            || fail "the tally line must count the staged finding:" "$fixture/a/out"

        # provides-versioning: the versioned soname provide is flagged with
        # its bare stem.
        run_engine "$ws" --qa-check provides-versioning
        [ "$FIXTURE_RC" = 0 ] || fail "provides-versioning is rc 0, got $FIXTURE_RC"
        vgrep "$FIXTURE_OUTPUT" -Fqx \
            "provides-versioning: viol: soname provide 'libx.so.1' names a versioned soname — declare the bare stem 'libx.so'" \
            || fail "the versioned soname provide must be named verbatim:" "$fixture/a/out"

        # swap-drift: the stock counterpart is missing from BOTH sides (the
        # two declarations the rule demands).
        run_engine "$ws" --qa-check swap-drift
        [ "$FIXTURE_RC" = 0 ] || fail "swap-drift is rc 0, got $FIXTURE_RC"
        vgrep "$FIXTURE_OUTPUT" -Fqx \
            "swap-drift: kit-git: stock counterpart 'kit' missing from provides — declare provides=('kit=\${pkgver}') so versioned dependents of the mapped name resolve here" \
            || { vgrep "$FIXTURE_OUTPUT" -Fq \
                "swap-drift: kit-git: stock counterpart 'kit' missing from provides — declare provides=('kit=\${pkgver}')" \
                || fail "the missing provides counterpart must be named verbatim:" "$fixture/a/out"; }
        vgrep "$FIXTURE_OUTPUT" -Fq \
            "swap-drift: kit-git: stock counterpart 'kit' missing from conflicts — declare conflicts=('kit')" \
            || fail "the missing conflicts counterpart must be named verbatim:" "$fixture/a/out"
        vgrep "$FIXTURE_OUTPUT" -Fqx "qa-check swap-drift: 2 finding(s)" \
            || fail "the tally must count the two counterpart findings:" "$fixture/a/out"

        # abi-closure with no built outputs: the loud skipped class (never a
        # vacuous clean).
        run_engine "$ws" --qa-check abi-closure
        [ "$FIXTURE_RC" = 0 ] || fail "a skipped check is rc 0, got $FIXTURE_RC"
        vgrep "$FIXTURE_OUTPUT" -Fqx \
            "qa-check abi-closure: skipped — no workspace-built outputs (build the recipes to enable the closure probe)" \
            || fail "the skipped witness must name its reason:" "$fixture/a/out"

        # The focus filter: one clean reference alone is clean.
        run_engine "$ws" --qa-check purged-tools clean
        [ "$FIXTURE_RC" = 0 ] || fail "the focus run is rc 0, got $FIXTURE_RC"
        vgrep "$FIXTURE_OUTPUT" -Fqx "qa-check purged-tools: clean" \
            || fail "the clean focus must report clean:" "$fixture/a/out"
    )
    echo "section a ok"
fi

if want b; then
    # ─── b. report-only enforcement: findings never touch the decision ────
    (
        set -euo pipefail
        ws="$fixture/b/ws"
        db="$fixture/b/db"
        make_workspace "$ws" 1 auto low
        qa_ws "$ws" "$db"
        add_package "$ws" viol "$gsa_meta_any"
        write_srcinfo "$ws" viol "pkgbase = viol
	pkgver = 1.0.0
	pkgrel = 1
	arch = any
	provides = libx.so.1
	makedepends = cuda
pkgname = viol"
        stage_archive "$ws" viol viol viol
        archive="$ws/packages/viol/viol-1.0.0-1-any.pkg.tar.zst"

        # The decision seam: the lint violations must NOT refuse anything —
        # rows stay install/skip/noop/parked (§E.3), rc 0 (§E.5).
        run_engine "$ws" --install-decide checked "$archive"
        [ "$FIXTURE_RC" = 0 ] || fail "a lint-violating plan stays rc 0 (§E.5), got $FIXTURE_RC: $FIXTURE_OUTPUT"
        grep < <(decision_rows) -Eq '^viol install ok$' \
            || fail "the clean install decision must survive the lint findings:" "$FIXTURE_OUTPUT"
        if grep < <(decision_rows) -q ' refuse '; then
            fail "a report-severity finding must never emit a refuse row (§E.4):" "$FIXTURE_OUTPUT"
        fi

        # The install run: transacts normally (stub log proves one pacman
        # -U), the run record says success, and the findings appear ONLY in
        # the prose QA block (additive — no machine rows, format: 2 intact).
        run_engine "$ws" -U --state-dir "$fixture/b/state" --config "$ws/pacman.conf" viol
        [ "$FIXTURE_RC" = 0 ] || fail "a lint-violating install run is rc 0 (§G.1), got $FIXTURE_RC: $FIXTURE_OUTPUT"
        [ "$(grep -c '^pacman ' "$GSA_FAKE_PACMAN_LOG")" = 1 ] \
            || fail "the transaction must run exactly once:" "$GSA_FAKE_PACMAN_LOG"
        [ "$(record_scalar outcome)" = success ] || fail "record outcome must be success:" "$FIXTURE_OUTPUT"
        [ "$(record_scalar rc)" = 0 ] || fail "record rc must be 0:" "$FIXTURE_OUTPUT"
        vgrep "$FIXTURE_OUTPUT" -Fq "QA report (report-only): 2 finding(s)" \
            || fail "the QA block must count the two staged violations:" "$fixture/b/out"
        grep < <(qa_lines) -Fq "purged-tools: viol: makedepends reintroduces purged tool 'cuda'" \
            || fail "the purged finding must be in the QA block:" "$FIXTURE_OUTPUT"
        grep < <(qa_lines) -Fq "provides-versioning: viol: soname provide 'libx.so.1'" \
            || fail "the provides finding must be in the QA block:" "$FIXTURE_OUTPUT"
        if grep < <(record_section plan) -q refused; then
            fail "the machine plan rows must not carry a refusal:" "$FIXTURE_OUTPUT"
        fi
        # The rule-9 registration still lands: report findings never skip it.
        grep -q '^IgnorePkg = viol' "$ws/pacman.conf" \
            || fail "the IgnorePkg registration must still land:" "$ws/pacman.conf"
    )
    echo "section b ok"
fi

if want c; then
    # ─── c. install-refusing check: refuse rows, rc 3, pacman-free ────────
    (
        set -euo pipefail
        ws="$fixture/c/ws"
        db="$fixture/c/db"
        make_workspace "$ws" 1 auto low
        qa_ws "$ws" "$db"
        # The stale shape: the recipe's committed .SRCINFO declares pkgbase
        # `stale`, but the archive's .PKGINFO names pkgbase `stale-ghost` —
        # rule 9 would register `stale-ghost` into IgnorePkg, a name no
        # recipe declares (it could shadow a real stock package).
        add_package "$ws" stale "$gsa_meta_any"
        write_srcinfo "$ws" stale "pkgbase = stale
	pkgver = 1.0.0
	pkgrel = 1
	arch = any
pkgname = stale"
        stage_archive "$ws" stale stale-ghost stale
        archive="$ws/packages/stale/stale-1.0.0-1-any.pkg.tar.zst"
        cp "$ws/pacman.conf" "$fixture/c/conf.pre"

        # The seam: the refusing finding is a `refuse stale-ignorepkg …` row
        # with the keyword first (§E.3), rc 1 (§E.5).
        run_engine "$ws" --install-decide checked "$archive"
        [ "$FIXTURE_RC" = 1 ] || fail "a refusing plan is rc 1 (§E.5), got $FIXTURE_RC: $FIXTURE_OUTPUT"
        grep < <(decision_rows) -Eq "^stale-ghost refuse stale-ignorepkg $archive stale-ghost not-declared$" \
            || fail "the refuse row must name the keyword, archive and name:" "$FIXTURE_OUTPUT"

        # Force mode never bypasses a gate (it bypasses only the same-version
        # skip): the same refusal.
        run_engine "$ws" --install-decide force "$archive"
        [ "$FIXTURE_RC" = 1 ] || fail "force mode must not bypass the QA gate (§E.3), got $FIXTURE_RC: $FIXTURE_OUTPUT"
        grep < <(decision_rows) -q ' refuse stale-ignorepkg ' \
            || fail "the refusing row must survive force mode:" "$FIXTURE_OUTPUT"

        # The install run: the rc 3 refusal class (§G.1) with the full run
        # record emitted (§H.1), and pacman/sudo/registration untouched
        # (rule 25(h): a refusing plan is pacman-free end to end).
        run_engine "$ws" -U --state-dir "$fixture/c/state" --config "$ws/pacman.conf" stale
        [ "$FIXTURE_RC" = 3 ] || fail "an install refusal is rc 3 (§G.1), got $FIXTURE_RC: $FIXTURE_OUTPUT"
        vgrep "$FIXTURE_OUTPUT" -q '^--- run record begin ---$' \
            || fail "a refused run still emits the run record (§H.1):" "$fixture/c/out"
        [ "$(record_scalar outcome)" = refused ] || fail "record outcome must be refused:" "$FIXTURE_OUTPUT"
        [ "$(record_scalar rc)" = 3 ] || fail "record rc must be 3:" "$FIXTURE_OUTPUT"
        grep < <(record_section plan) -q ' refused ' \
            || fail "the record's plan rows must carry the refusal:" "$FIXTURE_OUTPUT"
        [ ! -s "$GSA_FAKE_PACMAN_LOG" ] || fail "a refusing plan must make zero pacman calls:" "$GSA_FAKE_PACMAN_LOG"
        [ ! -s "$GSA_FAKE_SUDO_LOG" ] || fail "a refusing plan must never escalate:" "$GSA_FAKE_SUDO_LOG"
        cmp -s "$ws/pacman.conf" "$fixture/c/conf.pre" \
            || fail "a refusing plan must never rewrite the IgnorePkg closure:" "$ws/pacman.conf"

        # Through the named seam the same finding is the refusal class (rc 3,
        # §G) — the severity attribute speaks in both surfaces.
        run_engine "$ws" --qa-check stale-ignorepkg
        [ "$FIXTURE_RC" = 3 ] || fail "an install-refusing finding is rc 3 at the seam (§G), got $FIXTURE_RC"
        vgrep "$FIXTURE_OUTPUT" -q '^stale-ignorepkg: stale-ghost: ' \
            || fail "the seam must print the finding:" "$fixture/c/out"
    )
    echo "section c ok"
fi

if want d; then
    # ─── d. unknown check / missing name / unknown ref: rc 2 (§G) ─────────
    (
        set -euo pipefail
        ws="$fixture/d/ws"
        db="$fixture/d/db"
        make_workspace "$ws" 1 auto low
        qa_ws "$ws" "$db"
        add_package "$ws" clean "$gsa_meta_any"
        write_srcinfo "$ws" clean "pkgbase = clean
	pkgver = 1.0.0
	pkgrel = 1
	arch = any
pkgname = clean"

        run_engine "$ws" --qa-check no-such-check
        [ "$FIXTURE_RC" = 2 ] || fail "an unknown check name is rc 2 (§G), got $FIXTURE_RC: $FIXTURE_OUTPUT"
        vgrep "$FIXTURE_OUTPUT" -q "unknown check 'no-such-check'" \
            || fail "the unknown name must be named:" "$fixture/d/out"
        vgrep "$FIXTURE_OUTPUT" -q 'purged-tools' \
            || fail "the known roster must be printed (a keyword is never auto-corrected):" "$fixture/d/out"

        run_engine "$ws" --qa-check
        [ "$FIXTURE_RC" = 2 ] || fail "a missing check name is rc 2 (§G), got $FIXTURE_RC"
        vgrep "$FIXTURE_OUTPUT" -q 'requires a check name' \
            || fail "the missing name must be reported:" "$fixture/d/out"

        run_engine "$ws" --qa-check purged-tools nonesuch
        [ "$FIXTURE_RC" = 2 ] || fail "an unknown recipe reference is rc 2 (§G), got $FIXTURE_RC"
        vgrep "$FIXTURE_OUTPUT" -q "unknown recipe reference 'nonesuch'" \
            || fail "the unknown reference must be named:" "$fixture/d/out"
    )
    echo "section d ok"
fi
