#!/usr/bin/env bash
set -euo pipefail

# tests/sync-snapshot.sh — the W5 SNAPSHOT-PIN provider of `gsa -Sy`
# (docs/gsa-contract.md §B.4, the 2026-11-12 amendment; rule 18's
# "never observed apart" applied to a pin and its version).
#
# A snapshot recipe is one whose source carries `#commit=<sha>`. The pass
# advances that pin to the last commit at or before the most recent Monday
# 00:00 UTC, resolved from the recipe's OWN `SRCDEST` mirror (never a live
# query at edit time), and writes the pin and `pkgver=` in ONE transaction.
# Everything here is synthetic and $TMPDIR-scoped: the mirrors are local bare
# repositories this fixture builds, so the pass reads real git evidence with
# no network, and the version comes from the recipe's own `pkgver()` running
# inside a real checkout — the fixture supplies no version of its own.
#
# Pinned here (five ( subshell ) sections):
#   1. the pin MOVES and the version follows it: a bare mirror with one commit
#      a week before the boundary, one a second before it, and one after it;
#      a recipe pinned at the oldest → `-Sy` rewrites `#commit=` to the
#      boundary commit and `pkgver=` to what `pkgver()` computes there, the
#      disposition row names `Monday snapshot`, and the rewrite is left
#      UNCOMMITTED (§B.4). A second pass is a no-op, so the pass can never
#      rewind a pin it just wrote.
#   1b. a genuinely SKEWED recipe (committed pkgver ≠ pkgver() at its own pin)
#      is named on the report and still leaves the pass coherent — and a
#      coherent one reports no skew, which is the arm that caught the
#      2026-11-12 false positive.
#   2. a NON-pin recipe is untouched: classified `not-a-snapshot`, the mirror
#      is never consulted, the PKGBUILD keeps its bytes, rc 0.
#   3. an absent mirror DEFERS, never fetches: rc 5, `source-unfetchable` +
#      `mirror-missing`, recipe byte-identical. This arm must never become an
#      integrity stop — one un-fetched mirror may not abort a full-set `-Sy`.
#   4. multi-source evaluation and makepkg's name rule: `pkgver()` reads a
#      SECOND source's checkout (`onlyoffice-git`'s shape, the 2026-11-12
#      defect), and an explicit `name::` prefix is the checkout name
#      VERBATIM — `onlyoffice.github.io` must not become `onlyoffice`, which
#      is what makepkg's `get_filename` guarantees.
#
# House conventions: `( subshell )` sections, inline oracles, `fail()`
# prefixes. `-Sy` is invoked through the §B.10 privileged wrapper with the
# streams split (the disposition block is stdout, policy notes are stderr) —
# the deviation tests/gsa-sync-v2.sh names, so both fixtures read the pass the
# same way. Assertions read the recipe BYTES and the disposition block, never
# scraped prose alone.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"

fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-sync-snapshot.XXXXXX")
# Root-safe cleanup: a privileged `-Sy` writes its state tree as root.
trap '/usr/bin/sudo -n rm -rf -- "$fixture" 2>/dev/null || rm -rf -- "$fixture" 2>/dev/null || true' EXIT

fail() {
    printf '%s\n' "$1" >&2
    if [ -n "${2:-}" ] && [ -f "$2" ]; then
        sed 's/^/    /' "$2" >&2
    fi
    exit 1
}

# ─── Knobs (declared here, in the change that introduces them; §D.2) ────────
rr2_stub_knob GSA_FAKE_SNAPSHOT_MAKEPKG_LOG \
    "sync-snapshot makepkg stub: invocation log (one line per --printsrcinfo)"

# ─── The engine under test (§L.10: the INSTALLED binary) ────────────────────
if [ -z "${GSA_TEST_GSA_BIN:-}" ]; then
    GSA_TEST_GSA_BIN=$(command -v gsa) || {
        printf 'contract §L.10: no installed gsa on PATH — install gsa-pm, or set GSA_TEST_GSA_BIN explicitly\n' >&2
        exit 1
    }
fi
[ -x "$GSA_TEST_GSA_BIN" ] || fail "the engine under test is not executable: $GSA_TEST_GSA_BIN"
export GSA_TEST_ENGINE=gsa
export GSA_TEST_GSA_BIN

run_sy() {
    local ws=$1 out=$2 err=$3 state=$4
    # Engine configuration (§B.11): the fixture's own directory, so the HOST's
    # /etc/gsa can never decide what a fixture reads. rr2_env_forward only
    # forwards GSA_*, so this must be in the environment before it runs.
    if [[ -z ${GSA_CONF_DIR:-} ]]; then
        export GSA_CONF_DIR="$ws/../.rr2-conf"
    fi
    local -a fwd=() env_args=()
    rr2_env_forward fwd
    local kv
    for kv in "${fwd[@]}"; do
        [[ $kv == GSA_STATE_DIR=* ]] && continue
        env_args+=("$kv")
    done
    env_args+=("GSA_STATE_DIR=$state")
    set +e
    (cd "$ws" && /usr/bin/sudo -n env "${env_args[@]}" \
        "$GSA_TEST_GSA_BIN" -Sy) >"$out" 2>"$err"
    SY_RC=$?
    set -e
}

# ─── The boundary, computed the same way the engine does ───────────────────
# The most recent Monday 00:00 UTC at or before now (contract §B.4). Deriving
# the fixture's commit dates FROM it makes the three cases unconditional: one
# commit is unambiguously before, one lands a second before the boundary, and
# one after it.
DOW=$(date -u +%u) # 1 = Monday
BOUNDARY=$(date -u -d "-$((DOW - 1)) days" '+%Y-%m-%d')T00:00:00Z
BEFORE_BOUNDARY=$(date -u -d "$BOUNDARY -1 second" '+%Y-%m-%dT%H:%M:%SZ')
WEEK_BEFORE=$(date -u -d "$BOUNDARY -7 days" '+%Y-%m-%dT%H:%M:%SZ')
AFTER_BOUNDARY=$(date -u -d "$BOUNDARY +1 day" '+%Y-%m-%dT%H:%M:%SZ')

# ─── Synthesis ──────────────────────────────────────────────────────────────

# git_env — one identity for every git call the fixture makes, and no injected
# agent-shell config (AGENTS.md rule 2: `safe.bareRepository=explicit` makes a
# bare mirror unusable).
git_env() {
    GIT_CONFIG_COUNT=0 git -c user.name=fixture -c user.email=fixture@invalid "$@"
}

# commit_at WORKTREE SUBJECT AT — commit the worktree's current bytes with a
# fixed committer date, so the boundary is a fact the fixture states.
commit_at() {
    local wt=$1 subject=$2 at=$3
    (cd "$wt" &&
        git_env add -A &&
        GIT_AUTHOR_DATE="$at" GIT_COMMITTER_DATE="$at" \
            git_env commit -q --allow-empty -m "$subject")
}

# make_mirror SRCDEST NAME — a BARE mirror shaped like the one makepkg keeps at
# `SRCDEST/<name>`, with one commit a week before the boundary, one a second
# before it (the commit the pin MUST advance to) and one after it (which the
# pass must never choose). Echoes the three shas: old, boundary, after.
make_mirror() {
    local srcdest=$1 name=$2
    local wt="$srcdest/.work/$name"
    mkdir -p "$wt"
    (cd "$wt" && git_env init -q -b main .)
    local -a shas=()
    local pair label at
    for pair in "old|$WEEK_BEFORE" "boundary|$BEFORE_BOUNDARY" "after|$AFTER_BOUNDARY"; do
        label=${pair%%|*}
        at=${pair#*|}
        printf '%s\n' "$label" >"$wt/tag"
        commit_at "$wt" "$label" "$at"
        shas+=("$(git_env -C "$wt" rev-parse HEAD)")
    done
    git_env clone -q --bare "$wt" "$srcdest/$name"
    printf '%s\n' "${shas[@]}"
}

# snapshot_recipe WS ID URL COMMIT PKGVER — a `#commit=`-pinned VCS recipe plus
# its topology record. `pkgver()` reads the checkout's `tag` file, the shape
# most upstream version functions have.
snapshot_recipe() {
    local ws=$1 id=$2 url=$3 commit=$4 pkgver=$5
    local dir="$ws/packages/$id"
    mkdir -p "$dir"
    {
        printf 'pkgname=%s\n' "$id"
        printf 'pkgver=%s\n' "$pkgver"
        printf 'pkgrel=1\n'
        printf 'arch=(any)\n'
        printf 'source=("%s::git+%s#commit=%s")\n' "$id" "$url" "$commit"
        printf 'pkgver() {\n'
        printf '    cd "$srcdir/%s"\n' "$id"
        printf '    cat tag\n'
        printf '}\n'
    } >"$dir/PKGBUILD"
    printf '%s|packages/%s|git|\n' "$id" "$id" >>"$ws/config/topology.conf"
}

# write_stub_pacman DIR — the Arch-provider oracle. The snapshot pass resolves
# a pinned recipe from its mirror and never queries the repos, so anything
# reaching here is a finding; `-Si` answers "not found", which is what a git
# recipe is to the official repos.
write_stub_pacman() {
    cat >"$1/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -u
exit 1
EOF
    chmod +x "$1/bin/pacman"
}

# write_stub_makepkg DIR — `--printsrcinfo` only: the `.SRCINFO` refresh a
# successful pin move performs. It reads the recipe it is pointed at, so a
# refreshed file is the new truth rather than a canned string.
write_stub_makepkg() {
    cat >"$1/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'makepkg %s\n' "$*" >>"${GSA_FAKE_SNAPSHOT_MAKEPKG_LOG:?}"
dir=""
prev=""
for a in "$@"; do
    [ "$prev" = "--dir" ] && dir=$a
    prev=$a
done
[ -n "$dir" ] || exit 1
pv=$(sed -n 's/^pkgver=//p' "$dir/PKGBUILD" | head -n1)
pr=$(sed -n 's/^pkgrel=//p' "$dir/PKGBUILD" | head -n1)
pn=$(sed -n 's/^pkgname=//p' "$dir/PKGBUILD" | head -n1)
printf 'pkgbase = %s\n' "$pn"
printf '\tpkgver = %s\n' "$pv"
printf '\tpkgrel = %s\n' "$pr"
printf '\tarch = any\n'
printf 'pkgname = %s\n' "$pn"
exit 0
EOF
    chmod +x "$1/bin/makepkg"
}

# srcdest_for WS DIR — point the engine at the fixture's own source mirror.
srcdest_for() {
    printf 'srcdest = %s\n' "$2" >"$1/../.rr2-conf/gsa.conf"
}

# ─── 1. the pin moves, the version follows it, uncommitted ─────────────────
(
    set -euo pipefail
    ws="$fixture/s1/ws"
    make_workspace "$ws" 1 1 low
    write_stub_pacman "$ws"
    write_stub_makepkg "$ws"
    export PATH="$ws/bin:$PATH"
    export GSA_FAKE_SNAPSHOT_MAKEPKG_LOG="$fixture/s1/makepkg.log"

    srcdest="$fixture/s1/srcdest"
    mkdir -p "$srcdest"
    mapfile -t shas < <(make_mirror "$srcdest" demo)
    old=${shas[0]}
    boundary=${shas[1]}
    # The recipe is pinned at the old commit and its committed `pkgver` is
    # what `pkgver()` computes there — a coherent recipe, so no skew is due.
    snapshot_recipe "$ws" demo "https://example.invalid/demo" "$old" old
    srcdest_for "$ws" "$srcdest"

    recipe="$ws/packages/demo"
    cp "$recipe/PKGBUILD" "$fixture/s1/PKGBUILD.pre"
    run_sy "$ws" "$fixture/s1/out" "$fixture/s1/err" "$fixture/s1/state"

    [ "$SY_RC" = 0 ] || fail "the snapshot pin move is rc 0, got $SY_RC:" "$fixture/s1/err"
    grep -F '(synced with Monday snapshot)' "$fixture/s1/out" >/dev/null \
        || fail "the disposition row does not name the Monday snapshot provider:" "$fixture/s1/out"
    grep -F 'snapshot pin' "$fixture/s1/err" >/dev/null \
        || fail "the pin move is not logged:" "$fixture/s1/err"
    grep -F "#commit=$boundary" "$recipe/PKGBUILD" >/dev/null \
        || fail "the pin was not advanced to the boundary commit:" "$recipe/PKGBUILD"
    if grep -F "#commit=$old" "$recipe/PKGBUILD" >/dev/null; then
        fail "the old pin survived the rewrite:" "$recipe/PKGBUILD"
    fi
    # The version came out of pkgver() at the new commit, not a guess: the
    # boundary commit's tag content is "boundary".
    grep -Fx 'pkgver=boundary' "$recipe/PKGBUILD" >/dev/null \
        || fail "pkgver= was not rewritten to pkgver()'s value at the new pin:" "$recipe/PKGBUILD"
    # No skew is due on a coherent recipe — a pin move is not a skew.
    if grep -F 'version skew' "$fixture/s1/err" >/dev/null; then
        fail "a coherent recipe reported a version skew:" "$fixture/s1/err"
    fi
    # Uncommitted (§B.4): the pass leaves the maintainer a diff.
    cmp -s "$fixture/s1/PKGBUILD.pre" "$recipe/PKGBUILD" \
        && fail "the rewrite did not change the recipe at all"

    # A second pass must not rewind the pin it just wrote.
    run_sy "$ws" "$fixture/s1/out2" "$fixture/s1/err2" "$fixture/s1/state"
    [ "$SY_RC" = 0 ] || fail "the second pass is rc 0, got $SY_RC:" "$fixture/s1/err2"
    grep -F 'no-change' "$fixture/s1/out2" >/dev/null \
        || fail "the second pass over a moved pin is a no-change:" "$fixture/s1/out2"
    grep -F "#commit=$boundary" "$recipe/PKGBUILD" >/dev/null \
        || fail "the second pass moved the pin again:" "$recipe/PKGBUILD"
)

# ─── 1b. a genuinely skewed recipe is NAMED, never silently re-derived ─────
(
    set -euo pipefail
    ws="$fixture/s1b/ws"
    make_workspace "$ws" 1 1 low
    write_stub_pacman "$ws"
    write_stub_makepkg "$ws"
    export PATH="$ws/bin:$PATH"
    export GSA_FAKE_SNAPSHOT_MAKEPKG_LOG="$fixture/s1b/makepkg.log"

    srcdest="$fixture/s1b/srcdest"
    mkdir -p "$srcdest"
    mapfile -t shas < <(make_mirror "$srcdest" demo)
    old=${shas[0]}
    # The committed pkgver is deliberately NOT what pkgver() says at that pin.
    snapshot_recipe "$ws" demo "https://example.invalid/demo" "$old" hand-edited
    srcdest_for "$ws" "$srcdest"

    recipe="$ws/packages/demo"
    run_sy "$ws" "$fixture/s1b/out" "$fixture/s1b/err" "$fixture/s1b/state"

    [ "$SY_RC" = 0 ] || fail "a skewed pin still advances, rc 0, got $SY_RC:" "$fixture/s1b/err"
    grep -F 'version skew found at the OLD pin' "$fixture/s1b/err" >/dev/null \
        || fail "the skew was not reported:" "$fixture/s1b/err"
    grep -F 'hand-edited' "$fixture/s1b/err" >/dev/null \
        || fail "the skew note does not name the recorded version:" "$fixture/s1b/err"
    # Both fields move together: the recipe leaves the pass coherent.
    grep -Fx 'pkgver=boundary' "$recipe/PKGBUILD" >/dev/null \
        || fail "the skewed recipe did not get the derived pkgver:" "$recipe/PKGBUILD"
)

# ─── 2. a recipe that is not a snapshot is untouched ───────────────────────
(
    set -euo pipefail
    ws="$fixture/s2/ws"
    make_workspace "$ws" 1 1 low
    add_package "$ws" floating
    write_stub_pacman "$ws"
    write_stub_makepkg "$ws"
    export PATH="$ws/bin:$PATH"
    export GSA_FAKE_SNAPSHOT_MAKEPKG_LOG="$fixture/s2/makepkg.log"
    srcdest="$fixture/s2/srcdest"
    mkdir -p "$srcdest"
    srcdest_for "$ws" "$srcdest"

    recipe="$ws/packages/floating"
    cp "$recipe/PKGBUILD" "$fixture/s2/PKGBUILD.pre"
    run_sy "$ws" "$fixture/s2/out" "$fixture/s2/err" "$fixture/s2/state"

    [ "$SY_RC" = 0 ] \
        || fail "a recipe that is not a snapshot is not an error, got $SY_RC:" "$fixture/s2/err"
    # The snapshot pass must not CLAIM it. A non-pin recipe that fell through
    # to the pin provider would ask for a mirror that does not exist and
    # defer (rc 5, mirror-missing); the Arch provider's own no-change reason
    # is what a workspace with no stable placement answers instead.
    grep -Fx 'INFO sync pkg=floating status=no-change reason=not-stable-staged' \
        "$fixture/s2/out" >/dev/null \
        || fail "a non-pin recipe was not answered by the Arch provider:" "$fixture/s2/out"
    if grep -F 'mirror-missing' "$fixture/s2/err" >/dev/null; then
        fail "the snapshot pass claimed a recipe with no pin:" "$fixture/s2/err"
    fi
    cmp -s "$fixture/s2/PKGBUILD.pre" "$recipe/PKGBUILD" \
        || fail "a non-snapshot recipe was rewritten:" "$recipe/PKGBUILD"
    if grep -F 'snapshot pin' "$fixture/s2/err" >/dev/null; then
        fail "a non-snapshot recipe reported a pin move:" "$fixture/s2/err"
    fi
)

# ─── 3. an absent mirror DEFERS; nothing is fetched, nothing is written ────
(
    set -euo pipefail
    ws="$fixture/s3/ws"
    make_workspace "$ws" 1 1 low
    write_stub_pacman "$ws"
    write_stub_makepkg "$ws"
    export PATH="$ws/bin:$PATH"
    export GSA_FAKE_SNAPSHOT_MAKEPKG_LOG="$fixture/s3/makepkg.log"

    # An EMPTY SRCDEST: the recipe's mirror was never fetched.
    srcdest="$fixture/s3/srcdest"
    mkdir -p "$srcdest"
    snapshot_recipe "$ws" demo "https://example.invalid/demo" \
        0123456789abcdef0123456789abcdef01234567 old
    srcdest_for "$ws" "$srcdest"

    recipe="$ws/packages/demo"
    cp "$recipe/PKGBUILD" "$fixture/s3/PKGBUILD.pre"
    run_sy "$ws" "$fixture/s3/out" "$fixture/s3/err" "$fixture/s3/state"

    [ "$SY_RC" = 5 ] \
        || fail "an absent mirror is a DEFERRAL (rc 5), never a refusal, got $SY_RC:" "$fixture/s3/err"
    grep -F 'demo: deferred (source-unfetchable)' "$fixture/s3/err" >/dev/null \
        || fail "the deferral does not name source-unfetchable:" "$fixture/s3/err"
    grep -F 'mirror-missing' "$fixture/s3/err" >/dev/null \
        || fail "the deferral does not name the mirror-missing evidence gap:" "$fixture/s3/err"
    if grep -F 'refusing to rewrite' "$fixture/s3/err" >/dev/null; then
        fail "an un-fetched mirror became an integrity stop:" "$fixture/s3/err"
    fi
    cmp -s "$fixture/s3/PKGBUILD.pre" "$recipe/PKGBUILD" \
        || fail "a deferred recipe was mutated:" "$recipe/PKGBUILD"
)

# ─── 4. multi-source evaluation + makepkg's name rule ─────────────────────
(
    set -euo pipefail
    ws="$fixture/s4/ws"
    make_workspace "$ws" 1 1 low
    write_stub_pacman "$ws"
    write_stub_makepkg "$ws"
    export PATH="$ws/bin:$PATH"
    export GSA_FAKE_SNAPSHOT_MAKEPKG_LOG="$fixture/s4/makepkg.log"

    srcdest="$fixture/s4/srcdest"
    mkdir -p "$srcdest"
    mapfile -t primary_shas < <(make_mirror "$srcdest" primary)
    primary_old=${primary_shas[0]}
    primary_boundary=${primary_shas[1]}
    mapfile -t v8_shas < <(make_mirror "$srcdest" onlyoffice.github.io)
    v8_pinned=${v8_shas[0]}

    # `pkgver()` reads the SECOND source's checkout, whose name carries a dot:
    # `onlyoffice.github.io` is a real makepkg source name, and a
    # `.git`-truncating name rule looks for `onlyoffice` instead — a mirror
    # that does not exist, so the pass would defer instead of evaluating.
    id=multi-git
    mkdir -p "$ws/packages/$id"
    {
        printf 'pkgname=%s\n' "$id"
        printf 'pkgver=stale\n'
        printf 'pkgrel=1\n'
        printf 'arch=(any)\n'
        printf 'source=(\n'
        printf '    "primary::git+https://example.invalid/primary#commit=%s"\n' "$primary_old"
        printf '    "onlyoffice.github.io::git+https://example.invalid/onlyoffice.github.io#commit=%s"\n' "$v8_pinned"
        printf ')\n'
        printf 'pkgver() {\n'
        printf '    cd "$srcdir/onlyoffice.github.io"\n'
        printf '    cat tag\n'
        printf '}\n'
    } >"$ws/packages/$id/PKGBUILD"
    printf '%s|packages/%s|git|\n' "$id" "$id" >>"$ws/config/topology.conf"
    srcdest_for "$ws" "$srcdest"

    recipe="$ws/packages/$id"
    run_sy "$ws" "$fixture/s4/out" "$fixture/s4/err" "$fixture/s4/state"

    [ "$SY_RC" = 0 ] \
        || fail "the multi-source pin pass is rc 0, got $SY_RC:" "$fixture/s4/err"
    grep -F "#commit=$primary_boundary" "$recipe/PKGBUILD" >/dev/null \
        || fail "the PRIMARY pin was not advanced:" "$recipe/PKGBUILD"
    # The second source stays at the pin the recipe already records (the pass
    # advances only the primary), so pkgver() must have run inside the dotted
    # checkout and read ITS tag — "old".
    grep -Fx 'pkgver=old' "$recipe/PKGBUILD" >/dev/null \
        || fail "pkgver() did not read the second source's checkout:" "$recipe/PKGBUILD"
    if grep -F 'mirror-missing' "$fixture/s4/err" >/dev/null; then
        fail "the dotted source name resolved to a missing mirror — makepkg's get_filename was not followed:" \
            "$fixture/s4/err"
    fi
)
