#!/usr/bin/env bash
set -euo pipefail

# The failure summary's continuation carries a copy-pasteable resume command.
# It used to carry only --lanes/--jobs/--intensity, so a resume of a run made
# with -i rebuilt the remaining packages WITHOUT installing them — while the
# tip printed directly below it said "add -s so already-built pkgs are
# skipped", and the code's own comment says to resume with "-s -i". Later
# packages then compile against the old installed ABIs, which is the rule-11
# hazard -i exists to prevent.
#
# This fixture fails a middle package so a remainder exists, and requires the
# resume command to preserve the flags that change what the resume means.
#
# Flip notes (docs/gsa-fixture-migration.md row `tests/resume-command.sh`):
# argv map: `--install` -> `gsa -S`, `--forceinstall` -> `gsa -Sf`, no-install
# -> `gsa -B`, `--no-deps` -> `--leaf` (§B.4/§B.6/§B.8). Two flags are ADDED so
# the kept pins still mean anything on the native engine: `--fail-fast` — gsa's
# default is cone-stop and these packages are INDEPENDENT, so without it p3
# would still dispatch after p2 failed and the "p3 never dispatched" pin (§I.3)
# could not stand; a `--fail-fast` failure exits 1 (§G.1) — and `--config
# <conf>`, the IgnorePkg registration target (gap G6: the engine names its conf
# explicitly instead of the fish `_IGNOREPKG_CONF` seam). R-3 retirement (§6):
# the `--install`/`--forceinstall` flag-EXISTENCE pins (:82-86, :100-108,
# :227-228) retire — §B.9 drops both spellings — and the kept behaviour (a
# resume preserves install/force semantics) re-pins as the continuation
# `command:` family prefix (`gsa -S ` / `gsa -Sf ` / `gsa -B `, §H.2). The
# resume command is now DATA (`rr2_continuation command`, §H.2), never a prose
# grep, and its `remaining:` is cross-checked against the rows-derived set
# (`rr2_remaining`) instead of being trusted alone. The 'ambient environment'
# prose pin becomes `env-required:` (§H.2) naming GSA_CPU_THREADS and
# GSA_MEMORY_GIB. Plan refusal re-pins per §E.3/§G.1/§H.3 (see the second
# DEVIATION below).
# DEVIATION (§H.2 mirrored-flag list vs the engine): the continuation's
# `mirror_flags` (crates/gsa-cli/src/record.rs:154) mirrors only family/force,
# `--leaf`, `--fail-fast`, `--state-dir`/`--config`, `--no-register-ignorepkg`,
# the prefetch knobs and the resolved `--lanes`/`--jobs`/`--intensity`; it
# never mirrors `--no-sync`, `--allow-broken-rustc`, `--skip*` or
# `--vcs-skip-tolerance` (they land in `deferred_flags`, record.rs:56-63).
# The old pins (:83, :101, :106, :121) required THOSE to survive a resume; that
# half is unpinnable on the engine and retires here — only what mirrors is
# pinned — and the scenarios no longer pass the unmirrorable flags (their
# live wiring belongs to the sync/toolchain stream).
# DEVIATION (plan-refusal re-pin, inventory §E.3): the decision-row spelling
# `p2 refuse partial-set …` is unreachable through `gsa --install-decide` —
# that seam takes direct archive paths only and never runs recipe discovery
# (crates/gsa-cli/src/install.rs `run_install_decide`), so a shrunken split set
# cannot refuse there. `gsa -U <ref>` renders `refused partial-set …` plan
# rows and `never-started … install-refused partial-set …` outcome rows in a
# strict-`format: 2`-parseable record (the cutover gap-(a) fix retired its
# `lanes: -` and phantom `refused empty-list` defects — pinned below through
# the -U record). The refusal ALSO re-pins through the -S run record: §E.3's
# decision `refuse partial-set <dir> <missing>` maps to the outcome reason
# `install-refused partial-set <dir> p2-extra` (§H.3; install.rs `install_step`
# prefixes `install-refused`), the run is `outcome: refused` rc 3 (§G.1), the
# package that never dispatched stays `never-started` (§H.3), and the refusal
# reaches no pacman.
#
# Nothing here touches the real repository: the workspace is synthetic under
# $TMPDIR, the state root is redirected under it (`GSA_STATE_DIR`, never
# /var/lib/gsa), and pacman/sudo stay stubs.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-resume-cmd.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    printf 'resume command fixture: %s\n' "$1" >&2
    exit 1
}

# ─── The engine under test: built into the fixture tree (scratch only).
# GSA_TEST_GSA_BIN, when already set to an executable, is that engine (the
# rr-v2.bash run_engine convention) and the scratch build is skipped. ──────
if [ -z "${GSA_TEST_GSA_BIN:-}" ]; then
    cargo build --offline --quiet --target-dir "$fixture/cargo" -p gsa-cli \
        --manifest-path "$gsa_repo_root/Cargo.toml" ||
        fail "cannot build the gsa binary for the fixture"
    GSA_TEST_GSA_BIN="$fixture/cargo/debug/gsa"
fi
[ -x "$GSA_TEST_GSA_BIN" ] || fail "the engine under test is not executable: $GSA_TEST_GSA_BIN"
export GSA_TEST_ENGINE=gsa
export GSA_TEST_GSA_BIN

# write_real_makepkg DIR — the scenario makepkg. Archives are REAL (a staged
# .PKGINFO tar): the engine's install discovery reads each archive's own
# .PKGINFO, so the old trivial empty-file stub would make every plan refuse
# `empty-list` before the scenario's own failure could happen. The named
# build failure keeps the fish stub's one knob (GSA_FAKE_FAIL_PACKAGE, in
# tests/lib/rr-v2.bash's declared vocabulary).
write_real_makepkg() {
    cat >"$1/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
id=$(basename "$PWD")
if [ "${GSA_FAKE_FAIL_PACKAGE:-}" = "$id" ]; then
    printf 'fake makepkg failing %s\n' "$PWD"
    exit 1
fi
stage="$PWD/.stage-$id"
mkdir -p "$stage"
{
    printf 'pkgbase = %s\n' "$id"
    printf 'pkgname = %s\n' "$id"
    printf 'pkgver = 1.0.0-1\n'
    printf 'arch = any\n'
} >"$stage/.PKGINFO"
tar --zstd -cf "$PWD/$id-1.0.0-1-any.pkg.tar.zst" -C "$stage" .PKGINFO
rm -rf "$stage"
printf 'fake makepkg %s\n' "$PWD"
exit 0
EOF
    chmod +x "$1/bin/makepkg"
}

# Three independent packages: p2 fails, so p3 is never dispatched and the
# record has something to resume. Stubs: real-archive makepkg (fail on
# GSA_FAKE_FAIL_PACKAGE), sudo passthrough, pacman log.
make_case_workspace() { # $1 = sandbox dir
    local dir=$1 id
    make_workspace "$dir" 1 2 low
    # Dynamic IgnorePkg registration target — per-case, never the host's
    # /etc/pacman.conf (the battery must be non-mutating). The engine takes
    # it as `--config` (gap G6).
    make_install_conf "$dir/pacman.conf"
    for id in p1 p2 p3; do
        add_package "$dir" "$id" $'pkgver=1.0.0\npkgrel=1\narch=(any)'
    done
    write_real_makepkg "$dir"
    stub_sudo "$dir"
    stub_pacman "$dir"
}

# run_expecting_failure <dir> <label> [engine flags...] -> RESUME_CMD, RESUME_SET
# A --fail-fast run whose middle package fails: rc 1 (§I.3/§G.1), the record
# reads back strict `format: 2`, and the continuation command ends with the
# rows-derived resume set — one owner for what remains.
run_expecting_failure() {
    local dir=$1 label=$2 rc
    shift 2
    export GSA_STATE_DIR="$dir/state"
    export GSA_FAKE_PACMAN_LOG="$dir/pacman.log"
    export GSA_FAKE_FAIL_PACKAGE=p2
    export GSA_CPU_THREADS=8
    export GSA_MEMORY_GIB=16
    export PATH="$dir/bin:$PATH"
    run_engine "$dir" "$@" p1 p2 p3
    RESUME_OUTPUT=$FIXTURE_OUTPUT
    rc=$FIXTURE_RC
    if ((rc != 1)); then
        printf '%s: a --fail-fast run whose middle package failed must exit 1 (§I.3/§G.1), got %s:\n%s\n' \
            "$label" "$rc" "$RESUME_OUTPUT" >&2
        exit 1
    fi
    if ! rr2_body <<<"$RESUME_OUTPUT" >/dev/null; then
        printf '%s: no complete format: 2 run record:\n%s\n' "$label" "$RESUME_OUTPUT" >&2
        exit 1
    fi
    if [[ $(rr2_scalar outcome <<<"$RESUME_OUTPUT") != failed ]]; then
        printf '%s: run record outcome is %s, want failed:\n%s\n' \
            "$label" "$(rr2_scalar outcome <<<"$RESUME_OUTPUT")" "$RESUME_OUTPUT" >&2
        exit 1
    fi
    RESUME_CMD=$(rr2_continuation command <<<"$RESUME_OUTPUT")
    # The record's own `remaining:` must agree with the rows (§H.2): the
    # suggestion and the record are one data structure, never two opinions.
    local derived listed
    derived=$(rr2_remaining <<<"$RESUME_OUTPUT" | tr '\n' ' ')
    derived=${derived% }
    listed=$(rr2_continuation remaining <<<"$RESUME_OUTPUT")
    if [[ "$derived" != "$listed" ]]; then
        printf '%s: remaining: [%s] disagrees with the rows-derived set [%s]:\n%s\n' \
            "$label" "$listed" "$derived" "$RESUME_OUTPUT" >&2
        exit 1
    fi
    RESUME_SET=$derived
    if [[ "$RESUME_CMD" != *" $RESUME_SET" ]]; then
        printf '%s: resume command does not end with the run-record resume set [%s]:\n  %s\n' \
            "$label" "$RESUME_SET" "$RESUME_CMD" >&2
        exit 1
    fi
}

# ─── A -S run must resume as -S, or it silently stops installing ───────────
dir="$fixture/with-install"
make_case_workspace "$dir"
run_expecting_failure "$dir" 'with -S' -S --leaf --fail-fast --config "$dir/pacman.conf"
if [[ "$RESUME_CMD" != "gsa -S "* ]]; then
    printf 'with -S: resume command does not restate the install family:\n  %s\n' "$RESUME_CMD" >&2
    exit 1
fi
# What mirrors (§H.2) must survive: the selection semantics (--leaf), the
# failure policy (--fail-fast), the registration target (--config) and the
# resolved plan (--lanes/--jobs/--intensity). Unmirrorable flags are the
# DEVIATION in the header.
for flag in --leaf --fail-fast --config --lanes --jobs --intensity; do
    if [[ "$RESUME_CMD" != *"$flag"* ]]; then
        printf 'with -S: resume command dropped %s:\n  %s\n' "$flag" "$RESUME_CMD" >&2
        exit 1
    fi
done
if [[ "$RESUME_CMD" != *"$dir/pacman.conf"* ]]; then
    printf 'with -S: resume command dropped the IgnorePkg registration target:\n  %s\n' \
        "$RESUME_CMD" >&2
    exit 1
fi
if [[ "$RESUME_CMD" != *"p3"* ]]; then
    printf 'with -S: resume command does not name the unbuilt package:\n  %s\n' \
        "$RESUME_CMD" >&2
    exit 1
fi

# ─── A -Sf run must resume as -Sf, keeping the force semantics ─────────────
# The `f` is one cluster letter preserving both halves (build+install AND
# always-transact); the resume must carry `gsa -Sf`, never both spellings.
dir="$fixture/with-forceinstall"
make_case_workspace "$dir"
run_expecting_failure "$dir" 'with -Sf' -Sf --leaf --fail-fast --config "$dir/pacman.conf"
if [[ "$RESUME_CMD" != "gsa -Sf "* ]]; then
    printf 'with -Sf: resume command does not restate the force family:\n  %s\n' "$RESUME_CMD" >&2
    exit 1
fi
if [[ "$RESUME_CMD" == "gsa -S "* ]]; then
    printf 'with -Sf: resume carries both the -S and -Sf spellings:\n  %s\n' \
        "$RESUME_CMD" >&2
    exit 1
fi
for flag in --leaf --fail-fast --config; do
    if [[ "$RESUME_CMD" != *"$flag"* ]]; then
        printf 'with -Sf: resume command dropped %s:\n  %s\n' "$flag" "$RESUME_CMD" >&2
        exit 1
    fi
done
if [[ "$RESUME_CMD" != *"p3"* ]]; then
    printf 'with -Sf: resume command does not name the unbuilt package:\n  %s\n' \
        "$RESUME_CMD" >&2
    exit 1
fi

# ─── A build-only run must NOT acquire install semantics on resume ─────────
dir="$fixture/without-install"
make_case_workspace "$dir"
run_expecting_failure "$dir" 'without -S' -B --leaf --fail-fast
if [[ "$RESUME_CMD" == gsa\ -S* ]]; then
    printf 'without -S: resume command invented install semantics:\n  %s\n' "$RESUME_CMD" >&2
    exit 1
fi
if [[ "$RESUME_CMD" != "gsa -B "* ]]; then
    printf 'without -S: resume command does not restate the build-only family:\n  %s\n' \
        "$RESUME_CMD" >&2
    exit 1
fi
if [[ "$RESUME_CMD" != *"p3"* ]]; then
    printf 'without -S: resume command does not name the unbuilt package:\n  %s\n' \
        "$RESUME_CMD" >&2
    exit 1
fi

# ─── The FAILED package itself must be in the resume set (2026-09-26 bug) ───
# The summary used to compute the resume set as selection minus
# succeeded+failed, which DROPPED the failed package: a user copying the
# suggested command rebuilt only the not-yet-attempted packages and silently
# left the failed one stale, so its dependents then built against the stale
# installed copy. The resume set is DATA now — the record's non-succeeded rows
# in row order, p2 (failed, must rebuild first) before p3 (never started) —
# and both the resume command and the `remaining:` line follow it.
dir="$fixture/failed-included"
make_case_workspace "$dir"
run_expecting_failure "$dir" 'failed included' -B --leaf --fail-fast
if ! grep -qw 'p2' <<<"$RESUME_CMD"; then
    printf 'failed included: resume command drops the FAILED package:\n  %s\n' \
        "$RESUME_CMD" >&2
    exit 1
fi
if ! grep -qw 'p3' <<<"$RESUME_CMD"; then
    printf 'failed included: resume command drops the unbuilt package:\n  %s\n' \
        "$RESUME_CMD" >&2
    exit 1
fi
if [[ $(rr2_outcome p2 status <<<"$RESUME_OUTPUT") != failed ]]; then
    printf 'failed included: p2 row is %s, want failed\n' \
        "$(rr2_outcome p2 <<<"$RESUME_OUTPUT")" >&2
    exit 1
fi
if [[ $(rr2_outcome p2 reason <<<"$RESUME_OUTPUT") != build-failed ]]; then
    printf 'failed included: p2 reason is %s, want build-failed\n' \
        "$(rr2_outcome p2 reason <<<"$RESUME_OUTPUT")" >&2
    exit 1
fi
if [[ $(rr2_outcome p3 status <<<"$RESUME_OUTPUT") != never-started ]]; then
    printf 'failed included: p3 row is %s, want never-started\n' \
        "$(rr2_outcome p3 <<<"$RESUME_OUTPUT")" >&2
    exit 1
fi
if [[ "$RESUME_SET" != 'p2 p3' ]]; then
    printf 'failed included: resume set must be p2 (failed) then p3 (unbuilt), got: %s\n' \
        "$RESUME_SET" >&2
    exit 1
fi

# ─── An install-PLAN refusal fails the RUN and lands in the record ──────────
# R-F39/F25 family: the plan's status is never dropped. p2's built set is a
# PARTIAL split set (its second output never appears), so its install plan
# refuses with the named row instead of installing a subset or reporting
# "nothing to do" — p2's row names the omission (`install-refused partial-set
# <dir> p2-extra`, the §E.3 `refuse partial-set` decision seen through the
# §H.3 outcome reason), the run is `outcome: refused` rc 3 (§G.1), p3 is
# `never-started` (dispatch halted), the refusal reaches no pacman, and the
# resume suggestion keeps the install family and the not-yet-installed
# remainder. The expectation for the missing output is the committed
# .SRCINFO's pkgname list (engine truth: discover_recipe, crates/gsa-install
# src/lib.rs) — the flip stages that file where the fish plan read the
# PKGBUILD's pkgname array.
(
    dir="$fixture/plan-refusal"
    make_workspace "$dir" 1 2 low
    make_install_conf "$dir/pacman.conf"
    add_package "$dir" p1 $'pkgver=1.0.0\npkgrel=1\narch=(any)'
    add_package "$dir" p2 $'pkgver=1.0.0\npkgrel=1\narch=(any)\npkgname=(p2 p2-extra)'
    add_package "$dir" p3 $'pkgver=1.0.0\npkgrel=1\narch=(any)'
    printf 'pkgbase = p2\npkgname = p2\npkgname = p2-extra\npkgver = 1.0.0\npkgrel = 1\n' \
        >"$dir/packages/p2/.SRCINFO"
    write_real_makepkg "$dir"
    stub_sudo "$dir"
    stub_pacman "$dir"
    : >"$dir/pacman.log"
    export GSA_STATE_DIR="$dir/state"
    export GSA_FAKE_PACMAN_LOG="$dir/pacman.log"
    export GSA_CPU_THREADS=8
    export GSA_MEMORY_GIB=16
    export PATH="$dir/bin:$PATH"
    unset GSA_FAKE_FAIL_PACKAGE || true
    run_engine "$dir" -S --leaf --fail-fast --config "$dir/pacman.conf" p1 p2 p3
    RESUME_OUTPUT=$FIXTURE_OUTPUT
    if ((FIXTURE_RC != 3)); then
        printf 'plan refusal: an install refusal must exit 3 (§G.1), got %s:\n%s\n' \
            "$FIXTURE_RC" "$RESUME_OUTPUT" >&2
        exit 1
    fi
    if ! rr2_body <<<"$RESUME_OUTPUT" >/dev/null; then
        printf 'plan refusal: no complete format: 2 run record:\n%s\n' "$RESUME_OUTPUT" >&2
        exit 1
    fi
    if [[ $(rr2_scalar outcome <<<"$RESUME_OUTPUT") != refused ]] ||
        [[ $(rr2_scalar rc <<<"$RESUME_OUTPUT") != 3 ]]; then
        printf 'plan refusal: record is outcome %s rc %s, want refused 3:\n%s\n' \
            "$(rr2_scalar outcome <<<"$RESUME_OUTPUT")" \
            "$(rr2_scalar rc <<<"$RESUME_OUTPUT")" "$RESUME_OUTPUT" >&2
        exit 1
    fi
    p2_reason=$(rr2_outcome p2 reason <<<"$RESUME_OUTPUT")
    if [[ "$p2_reason" != "install-refused partial-set $dir/packages/p2 p2-extra" ]]; then
        printf 'plan refusal: p2 reason is %s, want install-refused partial-set %s/packages/p2 p2-extra:\n%s\n' \
            "$p2_reason" "$dir" "$RESUME_OUTPUT" >&2
        exit 1
    fi
    if [[ $(rr2_outcome p3 status <<<"$RESUME_OUTPUT") != never-started ]]; then
        printf 'plan refusal: p3 row is %s, want never-started:\n%s\n' \
            "$(rr2_outcome p3 <<<"$RESUME_OUTPUT")" "$RESUME_OUTPUT" >&2
        exit 1
    fi
    RESUME_CMD=$(rr2_continuation command <<<"$RESUME_OUTPUT")
    if [[ "$RESUME_CMD" != "gsa -S "* ]]; then
        printf 'plan refusal: resume command dropped the install family:\n  %s\n' "$RESUME_CMD" >&2
        exit 1
    fi
    for pkg in p2 p3; do
        if ! grep -qw "$pkg" <<<"$RESUME_CMD"; then
            printf 'plan refusal: resume command drops %s:\n  %s\n' "$pkg" "$RESUME_CMD" >&2
            exit 1
        fi
    done
    # The refusal is pacman-free end to end (rule 25(h)): only p1's
    # transaction may appear — and the toolchain gate's read-only
    # `pacman -Q rust-git` probe (crates/gsa-recipe/src/toolchain.rs) is a
    # query, not a transaction (the query/transaction split
    # tests/pacman-mutex-shim.sh pins), so it may ride in the log.
    if grep -v -e '^pacman -Q' -e "p1-1.0.0-1-any.pkg.tar.zst" "$dir/pacman.log" | grep -q .; then
        printf 'plan refusal: a refused plan reached pacman:\n' >&2
        cat "$dir/pacman.log" >&2
        exit 1
    fi

    # ── the -U <ref> rendering of the same refusal (cutover gap (a)) ──────
    # The discovery path renders `refused partial-set …` plan rows and
    # `never-started … install-refused partial-set …` outcome rows, and the
    # record is strict-`format: 2`-parseable (integer budget scalars) with
    # NO phantom `refused empty-list` row: §E.3's `empty-list` belongs to a
    # genuinely empty candidate plan, never to a plan whose rows already
    # explain the refusal.
    : >"$dir/pacman.log"
    run_engine "$dir" -U --state-dir "$dir/u-state" --config "$dir/pacman.conf" p2
    U_OUTPUT=$FIXTURE_OUTPUT
    if ((FIXTURE_RC != 3)); then
        printf 'plan refusal (-U): a partial-set refusal must exit 3 (§G.1), got %s:\n%s\n' \
            "$FIXTURE_RC" "$U_OUTPUT" >&2
        exit 1
    fi
    if ! rr2_body <<<"$U_OUTPUT" >/dev/null; then
        printf 'plan refusal (-U): the -U record is not strict-format-2-parseable:\n%s\n' "$U_OUTPUT" >&2
        exit 1
    fi
    if [[ $(rr2_plan p2 plan <<<"$U_OUTPUT") != refused ]] ||
        [[ $(rr2_plan p2 reason <<<"$U_OUTPUT") != "partial-set $dir/packages/p2 p2-extra" ]]; then
        printf 'plan refusal (-U): p2 plan row is [%s], want [refused partial-set %s/packages/p2 p2-extra]:\n%s\n' \
            "$(rr2_plan p2 <<<"$U_OUTPUT")" "$dir" "$U_OUTPUT" >&2
        exit 1
    fi
    if rr2_plan_rows <<<"$U_OUTPUT" | grep -q 'empty-list'; then
        printf 'plan refusal (-U): phantom empty-list row in a self-explaining refusal plan:\n%s\n' "$U_OUTPUT" >&2
        exit 1
    fi
    if [[ $(rr2_scalar rc <<<"$U_OUTPUT") != 3 ]]; then
        printf 'plan refusal (-U): record rc is %s, want 3:\n%s\n' \
            "$(rr2_scalar rc <<<"$U_OUTPUT")" "$U_OUTPUT" >&2
        exit 1
    fi
)

# ─── Ambient CPU/RAM pins are named in env-required, or a resume silently
# re-plans ─────────────────────────────────────────────────────────────────
# continuation_args warned about GSA_TARGET_CPU/GSA_STATE_DIR/
# GSA_VCS_SKIP_TOLERANCE but not GSA_CPU_THREADS/GSA_MEMORY_GIB — yet the
# core-solo job budget recomputes from them at every start, so a resume under
# different pins silently changed the plan (2026-10-05). The engine's
# `env-required:` (§H.2) names every roster variable the run actually read.
dir="$fixture/ambient-pins"
make_case_workspace "$dir"
run_expecting_failure "$dir" 'ambient pins' -B --leaf --fail-fast
env_required=$(rr2_continuation env-required <<<"$RESUME_OUTPUT")
for var in GSA_CPU_THREADS GSA_MEMORY_GIB; do
    if ! grep -qw "$var" <<<"$env_required"; then
        printf 'ambient pins: %s is not named in env-required [%s]:\n%s\n' \
            "$var" "$env_required" "$RESUME_OUTPUT" >&2
        exit 1
    fi
done

printf 'resume command fixture: PASS\n'
