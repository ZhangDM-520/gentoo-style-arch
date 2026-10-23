#!/usr/bin/env bash
set -euo pipefail

# tests/gsa-abi-v2.sh — the ABI subsystem of the NATIVE engine (`gsa`,
# docs/gsa-contract.md §B.3/§E/§I/§J; plan-native-pm.md §4;
# plan-gentoo-qol.md M1+M2). Everything is synthetic: $TMPDIR workspaces,
# stub `makepkg`/`sudo`/`pacman`/`pacman-conf`, a fabricated pacman local
# DB whose `files` entries are this fixture's own paths, and a per-section
# state root — the real /var/lib/gsa and /var/lib/pacman are never read or
# written (asserted at fixture end).
#
# Expectations are DERIVED (rule 25(j) / contract §L.3): the wave a run must
# report is computed from this fixture's own topology edges and the
# subscription records it seeded, and every token compared is read from the
# engine's own `-Qa` surface — never hardcoded.
#
# Pinned here (six ( subshell ) sections; run one alone with
# GSA_ABI_V2_ONLY=a…f):
#   a. token stability + the `abi-rev=` override (§J.4): the same archive
#      answers the same `-Qa` token twice; bumping `abi-rev=` moves the
#      effective token and LEAVES the derived hash unchanged (the override
#      wins over derivation's "unchanged"; derivation is never suppressed).
#   b. the computed wave (plan §4.2/§4.3): a provider whose registered
#      token moved against its consumers' recorded `:=` tokens drags exactly
#      the record-mismatch set plus its transitive consumers into the plan
#      (`abi-wave <provider> <member> <basis>` rows) — a consumer whose
#      record MATCHES stays out.
#   c. fail-toward-whole-closure (rule 25(c)): one direct consumer without
#      any record and the wave expands to the provider's FULL consumer
#      closure — a matching record cannot shrink the wave (never
#      under-expand).
#   d. under-coverage refusal (§E.3): a recorded subscriber the topology
#      cannot build refuses the run by name (`refuse abi-consumer-uncovered`),
#      rc 3, and the plan is pacman-free end to end (zero pacman lines).
#   e. the staged swap (plan §4.5): an `abi-rev=` bump moves the provider's
#      token with ZERO provide drift; the resulting wave lands in ONE
#      `pacman -U` carrying ALL of the wave's archives (provider first), the
#      member the user did not name riding along.
#   f. the `-Qa`/`-Qr` surfaces (§B.3): token/index-token/
#      subscription-in/subscription-out rows, and the revdep report naming
#      an unresolved `DT_NEEDED` by consumer, member and soname.
#
# Red-first (contract §L.4): the fail-toward default is mutation-probed —
# breaking it makes section (c) fail naming the under-expansion; the probe
# restores the source byte-identical and `touch`es it.
#
# House conventions: `( subshell )` sections (each an isolated scenario with
# its own workspace and state root), inline oracle stubs (§D.2), `fail()`
# prefixes, and tests/lib/rr-v2.bash's run_engine with GSA_TEST_ENGINE=gsa.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"

fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-abi-v2.XXXXXX")
# Root-safe cleanup: the engine writes its state tree as root (W5), so the
# plain rm would leave Permission denied noise even on a passing run.
trap '/usr/bin/sudo -n rm -rf -- "$fixture" 2>/dev/null || rm -rf -- "$fixture" 2>/dev/null || true' EXIT

fail() {
    printf '%s\n' "$1" >&2
    if [ -n "${2:-}" ] && [ -f "$2" ]; then
        sed 's/^/    /' "$2" >&2
    fi
    exit 1
}

# Section filter: GSA_ABI_V2_ONLY=<a..f> runs exactly one section.
want() { [ -z "${GSA_ABI_V2_ONLY:-}" ] || [ "${GSA_ABI_V2_ONLY}" = "$1" ]; }

# ─── Stub-knob vocabulary (§D.2: declared here in the change that adds them) ─
rr2_stub_knob GSA_FAKE_STAGE_DIR "gsa-abi-v2 makepkg stub: pre-staged build tree per package id (.PKGINFO lines + optional usr/)"

# The real /var/lib/gsa must never move under this fixture (§J.3's rule that
# fixtures live behind an override): snapshot its listing now and compare at
# the end.
varlib_before=$( (find /var/lib/gsa -printf '%p %s %T@\n' 2>/dev/null || true) | sort | md5sum)

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

# ─── Oracle stubs and derivation helpers (inline: §D.2 keeps oracles in the
# fixture that gives them meaning) ──────────────────────────────────────────

# write_elf64 FILE SONAME [NEEDED…] — one minimal ET_DYN (ehdr | PT_LOAD |
# PT_DYNAMIC | dyn entries | dynstr), the layout the ELF probe reads
# (crates/gsa-abi/src/test_support.rs::elf64). Two layout facts are
# load-bearing: e_phentsize is 56 (Elf64_Phdr) and PT_DYNAMIC's p_filesz
# counts EVERY dyn entry — DT_NULL, DT_STRTAB, DT_STRSZ included — or
# DT_STRSZ truncates and the probe reads empty needed/soname sets.
write_elf64() {
    local out=$1 soname=${2:-}
    shift 2
    local -a needed=("$@") tags=() vals=()
    local dynstr_len=1 dynstr_off total dyn_bytes n_entries cur s i
    n_entries=${#needed[@]}
    if [ -n "$soname" ]; then
        n_entries=$((n_entries + 1))
        dynstr_len=$((dynstr_len + ${#soname} + 1))
    fi
    for s in "${needed[@]}"; do
        dynstr_len=$((dynstr_len + ${#s} + 1))
    done
    n_entries=$((n_entries + 3)) # DT_STRTAB, DT_STRSZ, DT_NULL
    dynstr_off=$((64 + 56 + 56 + 16 * n_entries))
    total=$((dynstr_off + dynstr_len))
    dyn_bytes=$((16 * n_entries))
    cur=1
    if [ -n "$soname" ]; then
        tags+=(14)
        vals+=("$cur")
        cur=$((cur + ${#soname} + 1))
    fi
    for s in "${needed[@]}"; do
        tags+=(1)
        vals+=("$cur")
        cur=$((cur + ${#s} + 1))
    done
    tags+=(5)
    vals+=("$dynstr_off")
    tags+=(10)
    vals+=("$dynstr_len")
    tags+=(0)
    vals+=(0)
    u16() { printf "$(printf '\\x%02x\\x%02x' $(($1 & 255)) $((($1 >> 8) & 255)))"; }
    u32() {
        printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $(($1 & 255)) $((($1 >> 8) & 255)) \
            $((($1 >> 16) & 255)) $((($1 >> 24) & 255)))"
    }
    u64() {
        local v=$1 out='' i
        for i in $(seq 0 7); do out="$out$(printf '\\x%02x' $(((v >> (8 * i)) & 255)))"; done
        printf "$out"
    }
    {
        printf '\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00'
        u16 3; u16 62; u32 1; u64 0; u64 64; u64 0; u32 0
        u16 64; u16 56; u16 2; u16 64; u16 0; u16 0
        u32 1; u32 5; u64 0; u64 0; u64 0; u64 "$total"; u64 "$total"; u64 4096
        u32 2; u32 6; u64 176; u64 176; u64 176; u64 "$dyn_bytes"; u64 "$dyn_bytes"; u64 8
        for i in "${!tags[@]}"; do
            u64 "${tags[$i]}"
            u64 "${vals[$i]}"
        done
        printf '\x00'
        if [ -n "$soname" ]; then printf '%s\x00' "$soname"; fi
        for s in "${needed[@]}"; do printf '%s\x00' "$s"; done
    } >"$out"
}

# stage_pkginfo STAGE PKGBASE PKGNAME PKGVER [PKGLINE…] — the staged
# `.PKGINFO` of one hand-built archive (the metadata truth rule 9 makes
# authoritative).
stage_pkginfo() {
    local stage=$1 base=$2 name=$3 ver=$4
    shift 4
    mkdir -p "$stage"
    {
        printf 'pkgbase = %s\n' "$base"
        printf 'pkgname = %s\n' "$name"
        printf 'pkgver = %s\n' "$ver"
        printf 'arch = any\n'
        if [ "$#" -gt 0 ]; then
            printf '%s\n' "$@"
        fi
    } >"$stage/.PKGINFO"
}

# make_archive OUT STAGE — one real `.pkg.tar.zst` from a prepared stage dir
# (a single tar pass: a compressed archive can never be appended to).
make_archive() {
    local out=$1 stage=$2
    mkdir -p "$(dirname "$out")"
    if [ -d "$stage/usr" ]; then
        tar --zstd -cf "$out" -C "$stage" .PKGINFO usr
    else
        tar --zstd -cf "$out" -C "$stage" .PKGINFO
    fi
    rm -rf -- "$stage"
}

# db_entry DBROOT NAME FULL-VERSION [PROVIDE…] — one fabricated pacman
# local-DB entry (`<db>/local/<name>-<ver>/desc`), like the fish-era
# fixtures' DBs: the entry directory's mtime IS the install date
# (crates/gsa-install/src/localdb.rs), so the caller creates it AFTER the
# archives when the run must see the package as already current.
db_entry() {
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
    printf '%s\n' "$dir"
}

# db_file ENTRY-DIR ABS-PATH… — append owned files to an entry. The entries
# are the fixture's own absolute paths MINUS the leading slash: the probe
# resolves them at the exact host path, so every byte read stays under
# $fixture (hermetic probing, plan §4.6).
db_file() {
    local dir=$1
    shift
    local p
    for p in "$@"; do
        printf '%s\n' "${p#/}" >>"$dir/files"
    done
}

# write_stub_makepkg DIR — the scenario makepkg: one real `.pkg.tar.zst`
# per build from the fixture's pre-staged tree ($GSA_FAKE_STAGE_DIR/<id>),
# the version fixed at 1.0.0-1 (token stability is the subject here, not
# version churn).
write_stub_makepkg() {
    cat >"$1/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -eu
case " $* " in
*" --verifysource "*) exit 0 ;; # fetch children are advisory here
esac
id=$(basename "$PWD")
src="${GSA_FAKE_STAGE_DIR:?}/$id"
stage="$PWD/.stage-$id"
cp -a "$src" "$stage"
if [ -d "$stage/usr" ]; then
    tar --zstd -cf "$PWD/$id-1.0.0-1-any.pkg.tar.zst" -C "$stage" .PKGINFO usr
else
    tar --zstd -cf "$PWD/$id-1.0.0-1-any.pkg.tar.zst" -C "$stage" .PKGINFO
fi
rm -rf "$stage"
exit 0
EOF
    chmod +x "$1/bin/makepkg"
}

# write_stub_sudo DIR — the sudo passthrough stub (the engine may only ever
# run `sudo -n <cmd>`, §K.3).
write_stub_sudo() {
    cat >"$1/bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -u
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

# write_stub_pacman DIR — the transaction oracle: one `pacman …` argv line
# per invocation (the staged-swap sections count these).
write_stub_pacman() {
    cat >"$1/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'pacman %s\n' "$*" >>"${GSA_FAKE_PACMAN_LOG:?}"
exit 0
EOF
    chmod +x "$1/bin/pacman"
}

# write_stub_pacman_conf DIR DBROOT — `pacman-conf DBPath` answers the
# fixture's fabricated DB root, never the host's.
write_stub_pacman_conf() {
    cat >"$1/bin/pacman-conf" <<EOF
#!/usr/bin/env bash
set -u
if [ "\${1:-}" = DBPath ]; then
    printf '%s\n' "$2"
    exit 0
fi
exit 1
EOF
    chmod +x "$1/bin/pacman-conf"
}

# abi_ws WS DB STAGE-DIR — one workspace with all four stubs on PATH and the
# fabricated DB wired in.
abi_ws() {
    local ws=$1 db=$2 stage=$3
    write_stub_makepkg "$ws"
    write_stub_sudo "$ws"
    write_stub_pacman "$ws"
    write_stub_pacman_conf "$ws" "$db"
    export PATH="$ws/bin:$PATH"
    export GSA_FAKE_STAGE_DIR="$stage"
    export GSA_FAKE_PACMAN_LOG="$fixture/pacman.log"
    : >"$GSA_FAKE_PACMAN_LOG"
}

# stage_tree STAGE-DIR ID VER [PKGLINE…] — the pre-staged build tree the
# makepkg stub packages (no payload: token truth comes from .PKGINFO
# provides here).
stage_tree() {
    local stage=$1 id=$2 ver=$3
    shift 3
    stage_pkginfo "$stage/$id" "$id" "$id" "$ver" "$@"
}

# qa_row OUTPUT ID KIND — one `-Qa` row (`<id> <kind> …`).
qa_row() {
    printf '%s\n' "$1" | awk -v id="$2" -v kind="$3" '$1 == id && $2 == kind { print; exit }'
}

# sub_token STATE CONSUMER PROVIDER — the recorded token, empty when the
# record is absent.
sub_token() {
    awk -F'|' -v c="$2" -v p="$3" '$1 == c && $3 == p { print $4; exit }' \
        "$1/abi/subscriptions" 2>/dev/null || true
}

# assert_wave_rows BLOB WHAT — every `abi-wave` row carries the basis
# vocabulary.
assert_wave_rows() {
    local blob=$1 what=$2 bad
    bad=$(printf '%s\n' "$blob" | grep '^abi-wave ' | grep -Ev \
        '^abi-wave [^ ]+ [^ ]+ (recorded|unrecorded|content-truth|coupled-must|closure)$' || true)
    [ -z "$bad" ] || fail "$what: malformed abi-wave row(s): $bad"
}
# direct_consumers WS PROVIDER — ids whose edges name the provider (a
# build-order edge means "consumes": the consumer builds after it).
direct_consumers() {
    awk -F'|' -v p="$2" '{
        n = split($4, e, ",")
        for (i = 1; i <= n; i++) if (e[i] == p) print $1
    }' "$1/config/topology.conf"
}

# closure_of WS SEEDS… — the seeds plus every transitive consumer, one per
# line, sorted.
closure_of() {
    local ws=$1
    shift
    local out=" $* " front=" $* " next c d
    while [ -n "${front// /}" ]; do
        next=""
        for c in $front; do
            for d in $(direct_consumers "$ws" "$c"); do
                case "$out" in
                *" $d "*) ;;
                *)
                    out="$out$d "
                    next="$next$d "
                    ;;
                esac
            done
        done
        front=$next
    done
    tr ' ' '\n' <<<"$out" | sed '/^$/d' | sort -u
}

# expected_wave_members WS STATE PROVIDER NEW-TOKEN — the wave the records
# and edges demand (rule 25(j)): the record-mismatch direct consumers plus
# their transitive consumers; when ANY direct consumer has no record at all,
# the fail-toward-whole-closure default engages and the provider's FULL
# consumer closure rebuilds (a matching record cannot shrink it).
expected_wave_members() {
    local ws=$1 state=$2 prov=$3 new=$4 fallback=0 seeds='' c tok
    for c in $(direct_consumers "$ws" "$prov"); do
        tok=$(sub_token "$state" "$c" "$prov")
        if [ -z "$tok" ]; then
            fallback=1
        fi
    done
    if [ "$fallback" = 1 ]; then
        closure_of "$ws" "$prov" | grep -v "^$prov$"
    else
        for c in $(direct_consumers "$ws" "$prov"); do
            tok=$(sub_token "$state" "$c" "$prov")
            if [ "$tok" != "$new" ]; then
                seeds="$seeds $c"
            fi
        done
        closure_of "$ws" $seeds
    fi
}

# wave_members OUTPUT PROVIDER — the `abi-wave` rows' member set for one
# provider (sorted).
wave_members() {
    printf '%s\n' "$1" | awk -v p="$2" '$1 == "abi-wave" && $2 == p { print $3 }' | sort
}

if want a; then
    # ─── 1. token stability + the abi-rev= override (§J.4) ─────────────────
    (
        set -euo pipefail
        ws="$fixture/a/ws"
        state="$fixture/a/state"
        db="$fixture/a/db"
        make_workspace "$ws" 1 auto low
        abi_ws "$ws" "$db" "$fixture/a/stage"
        mkdir -p "$db"
        export GSA_STATE_DIR="$state"
        add_package "$ws" tok "$gsa_meta_any" git

        stage="$fixture/a/stage-tok"
        stage_pkginfo "$stage" tok tok "1.0.0-1" 'provides = libtok.so=1-64'
        mkdir -p "$stage/usr/lib"
        write_elf64 "$stage/usr/lib/libtok.so" libtok.so.1
        make_archive "$ws/packages/tok/tok-1.0.0-1-any.pkg.tar.zst" "$stage"

        run_engine "$ws" -Qa --state-dir "$state" tok
        [ "$FIXTURE_RC" = 0 ] || fail "a: -Qa on a built archive is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        first=$(qa_row "$FIXTURE_OUTPUT" tok token)
        [ -n "$first" ] || fail "a: -Qa prints a token row for tok: $FIXTURE_OUTPUT"
        vgrep "$first" -Eq \
            '^tok token [^ ]+ source=archive derived=[0-9a-f]+ -$' \
            || fail "a: token row shape (§B.3), got: $first"

        run_engine "$ws" -Qa --state-dir "$state" tok
        [ "$FIXTURE_RC" = 0 ] || fail "a: second -Qa is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        second=$(qa_row "$FIXTURE_OUTPUT" tok token)
        [ "$first" = "$second" ] \
            || fail "a: the same archive answers the same token (stability): $first vs $second"

        # The declared override: same archive, `abi-rev=7` on the record.
        set_topology_record "$ws" tok git "" "abi-rev=7"
        run_engine "$ws" -Qa --state-dir "$state" tok
        [ "$FIXTURE_RC" = 0 ] || fail "a: -Qa after the override is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        third=$(qa_row "$FIXTURE_OUTPUT" tok token)
        vgrep "$third" -Eq \
            '^tok token rev7-[0-9a-f]+ source=archive derived=[0-9a-f]+ abi-rev=7$' \
            || fail "a: the override wins over derivation (rev7-… token, abi-rev=7), got: $third"

        # Derived (rule 25(j): every comparison is engine-derived): the
        # derived hash is unchanged, the effective token moved.
        old_derived=$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^derived=/) { sub(/^derived=/, "", $i); print $i } }' <<<"$first")
        new_derived=$(awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^derived=/) { sub(/^derived=/, "", $i); print $i } }' <<<"$third")
        old_effective=$(awk '{ print $3 }' <<<"$first")
        new_effective=$(awk '{ print $3 }' <<<"$third")
        [ "$old_derived" = "$new_derived" ] \
            || fail "a: the derived hash must not move under an override: $old_derived vs $new_derived"
        [ "$old_effective" != "$new_effective" ] \
            || fail "a: the effective token must move with abi-rev=: $old_effective"
        [ "$new_effective" = "rev7-$new_derived" ] \
            || fail "a: effective = rev<n>-<derived>: $new_effective (derived $new_derived)"

        # And stable again under the override.
        run_engine "$ws" -Qa --state-dir "$state" tok
        [ "$(qa_row "$FIXTURE_OUTPUT" tok token)" = "$third" ] \
            || fail "a: the overridden token is stable too: $third"
        echo "section a ok"
    )
fi

if want b; then
    # ─── 2. the wave is the record-mismatch consumer set (plan §4.2/§4.3) ──
    (
        set -euo pipefail
        ws="$fixture/b/ws"
        state="$fixture/b/state"
        db="$fixture/b/db"
        make_workspace "$ws" 1 auto low
        abi_ws "$ws" "$db" "$fixture/b/stage"
        mkdir -p "$db"
        export GSA_STATE_DIR="$state"
        add_package "$ws" lib "$gsa_meta_any" git
        add_package "$ws" c1 "$gsa_meta_any" git
        add_package "$ws" c2 "$gsa_meta_any" git
        add_package "$ws" c3 "$gsa_meta_any" git
        set_topology_record "$ws" lib git "" ""
        set_topology_record "$ws" c1 git "lib" ""
        set_topology_record "$ws" c2 git "lib" ""
        set_topology_record "$ws" c3 git "c1" ""

        # One stub build pass registers every token in the binpkg index.
        stage_tree "$fixture/b/stage" lib "1.0.0-1" 'provides = libx.so=1-64'
        stage_tree "$fixture/b/stage" c1 "1.0.0-1"
        stage_tree "$fixture/b/stage" c2 "1.0.0-1"
        stage_tree "$fixture/b/stage" c3 "1.0.0-1"
        run_engine "$ws" -B --no-prefetch --state-dir "$state" lib c1 c2 c3
        [ "$FIXTURE_RC" = 0 ] || fail "b: the stub build pass is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"

        # Tokens come from the engine's own -Qa surface, never hardcoded.
        run_engine "$ws" -Qa --state-dir "$state" lib c1
        t_lib=$(qa_row "$FIXTURE_OUTPUT" lib token | awk '{ print $3 }')
        t_c1=$(qa_row "$FIXTURE_OUTPUT" c1 token | awk '{ print $3 }')
        [ -n "$t_lib" ] && [ -n "$t_c1" ] || fail "b: -Qa derived tokens for lib and c1: $FIXTURE_OUTPUT"

        # The records this fixture installs: c1 recorded a STALE token of
        # lib (mismatch → rebuild), c2 recorded lib's CURRENT token (match →
        # stays out), c3 recorded c1's current token (no c1 move at all).
        # Fixture-side writes into the engine-owned state tree (W5: state/ is
        # root-owned after the build pass above), so the seeded records land
        # through the real sudo — the record must exist regardless of owner.
        /usr/bin/sudo -n mkdir -p "$state/abi"
        {
            printf 'c1|0:1.0.0-1|lib|stale-token\n'
            printf 'c2|0:1.0.0-1|lib|%s\n' "$t_lib"
            printf 'c3|0:1.0.0-1|c1|%s\n' "$t_c1"
        } | /usr/bin/sudo -n tee "$state/abi/subscriptions" >/dev/null

        run_engine "$ws" -B --dry-run lib c1 c2 c3
        [ "$FIXTURE_RC" = 0 ] || fail "b: the plan is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        assert_wave_rows "$FIXTURE_OUTPUT" "b"
        expected=$(expected_wave_members "$ws" "$state" lib "$t_lib")
        got=$(wave_members "$FIXTURE_OUTPUT" lib)
        [ "$got" = "$expected" ] \
            || fail "b: wave must equal the record-mismatch set plus its closure (rule 25(j)): want [$expected], got [$got]:
$FIXTURE_OUTPUT"
        [ "$got" = "c1
c3" ] || fail "b: derived expectation must be the mismatch set + closure (c1, c3), got [$got]"
        # The matching record stays out — the wave never over-expands here.
        vgrep "$got" -qx c2 \
            && fail "b: c2's record MATCHES the provider token — it must stay out of the wave:"
        echo "section b ok"
    )
fi

if want c; then
    # ─── 3. fail-toward-whole-closure (rule 25(c): never under-expand) ─────
    (
        set -euo pipefail
        ws="$fixture/c/ws"
        state="$fixture/c/state"
        db="$fixture/c/db"
        make_workspace "$ws" 1 auto low
        abi_ws "$ws" "$db" "$fixture/c/stage"
        mkdir -p "$db"
        export GSA_STATE_DIR="$state"
        add_package "$ws" lib "$gsa_meta_any" git
        add_package "$ws" c1 "$gsa_meta_any" git
        add_package "$ws" c2 "$gsa_meta_any" git
        add_package "$ws" c3 "$gsa_meta_any" git
        set_topology_record "$ws" lib git "" ""
        set_topology_record "$ws" c1 git "lib" ""
        set_topology_record "$ws" c2 git "lib" ""
        set_topology_record "$ws" c3 git "lib" ""

        stage_tree "$fixture/c/stage" lib "1.0.0-1" 'provides = libx.so=1-64'
        stage_tree "$fixture/c/stage" c1 "1.0.0-1"
        stage_tree "$fixture/c/stage" c2 "1.0.0-1"
        stage_tree "$fixture/c/stage" c3 "1.0.0-1"
        run_engine "$ws" -B --no-prefetch --state-dir "$state" lib c1 c2 c3
        [ "$FIXTURE_RC" = 0 ] || fail "c: the stub build pass is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"

        run_engine "$ws" -Qa --state-dir "$state" lib
        t_lib=$(qa_row "$FIXTURE_OUTPUT" lib token | awk '{ print $3 }')
        [ -n "$t_lib" ] || fail "c: -Qa derived a token for lib: $FIXTURE_OUTPUT"

        # c1's record MATCHES (it would stay out of any exact wave), c2's
        # MISMATCHES (the move is observable), and c3 has NO record at all —
        # the missing record is what must fail toward the whole closure.
        # (W5: seeded through the real sudo — state/ is engine-owned.)
        /usr/bin/sudo -n mkdir -p "$state/abi"
        {
            printf 'c1|0:1.0.0-1|lib|%s\n' "$t_lib"
            printf 'c2|0:1.0.0-1|lib|stale-token\n'
        } | /usr/bin/sudo -n tee "$state/abi/subscriptions" >/dev/null

        run_engine "$ws" -B --dry-run lib c1 c2 c3
        [ "$FIXTURE_RC" = 0 ] || fail "c: the plan is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        assert_wave_rows "$FIXTURE_OUTPUT" "c"
        expected=$(expected_wave_members "$ws" "$state" lib "$t_lib")
        got=$(wave_members "$FIXTURE_OUTPUT" lib)
        [ "$got" = "$expected" ] \
            || fail "c: one missing record must fail toward the provider's FULL consumer closure (rule 25(c)): want [$expected], got [$got]:
$FIXTURE_OUTPUT"
        [ "$got" = "c1
c2
c3" ] || fail "c: derived expectation must be the full closure (c1, c2, c3), got [$got]"
        # A matching record cannot shrink the whole-closure rule, and the
        # missing record is NAMED `unrecorded` (the fail-toward markers).
        vgrep "$FIXTURE_OUTPUT" -q '^abi-wave lib c1 closure$' \
            || fail "c: c1 must join the wave despite its matching record (the fail-toward whole-closure sweep):
$FIXTURE_OUTPUT"
        vgrep "$FIXTURE_OUTPUT" -q '^abi-wave lib c3 unrecorded$' \
            || fail "c: the record-less consumer is named 'unrecorded' (the fail-toward default):
$FIXTURE_OUTPUT"
        echo "section c ok"
    )
fi

if want d; then
    # ─── 4. under-coverage refusal (§E.3: named, rc 3, pacman-free) ────────
    (
        set -euo pipefail
        ws="$fixture/d/ws"
        state="$fixture/d/state"
        db="$fixture/d/db"
        make_workspace "$ws" 1 auto low
        abi_ws "$ws" "$db" "$fixture/d/stage"
        export GSA_STATE_DIR="$state"
        add_package "$ws" lib "$gsa_meta_any" git
        add_package "$ws" c1 "$gsa_meta_any" git
        set_topology_record "$ws" lib git "" ""
        set_topology_record "$ws" c1 git "lib" ""

        stage="$fixture/d/stage-lib"
        stage_pkginfo "$stage" lib lib "1.0.0-1" 'provides = libx.so=1-64'
        mkdir -p "$stage/usr/lib"
        write_elf64 "$stage/usr/lib/libx.so" libx.so.1
        make_archive "$ws/packages/lib/lib-1.0.0-1-any.pkg.tar.zst" "$stage"
        db_entry "$db" lib "0:1.0.0-1" 'libx.so=1-64' >/dev/null

        # A recorded subscriber (`ghost`) the topology has no record for:
        # it can never be built here, so the swap is under-covered.
        # (W5: seeded through the real sudo — state/ may already be
        # engine-owned from an earlier section's runs.)
        /usr/bin/sudo -n mkdir -p "$state/abi"
        printf 'ghost|0:1.0.0-1|lib|stale-token\n' \
            | /usr/bin/sudo -n tee "$state/abi/subscriptions" >/dev/null

        run_engine "$ws" -U --state-dir "$state" --config "$ws/pacman.conf" lib
        [ "$FIXTURE_RC" = 3 ] \
            || fail "d: under-coverage refuses with rc 3 (§G.1), got $FIXTURE_RC: $FIXTURE_OUTPUT"
        vgrep "$FIXTURE_OUTPUT" -Eq '^ghost refused abi-consumer-uncovered lib$' \
            || fail "d: the refusal is named per member (§E.3), got:
$FIXTURE_OUTPUT"
        vgrep "$FIXTURE_OUTPUT" -q 'install-refused abi-consumer-uncovered lib' \
            || fail "d: the outcome names the refusal class, got:
$FIXTURE_OUTPUT"
        if grep -q '^pacman ' "$GSA_FAKE_PACMAN_LOG"; then
            fail "d: a refusing plan is pacman-free end to end (rule 25(h)):" "$GSA_FAKE_PACMAN_LOG"
        fi
        echo "section d ok"
    )
fi

if want e; then
    # ─── 5. the staged swap: ONE pacman -U per wave (plan §4.5) ────────────
    (
        set -euo pipefail
        ws="$fixture/e/ws"
        state="$fixture/e/state"
        db="$fixture/e/db"
        make_workspace "$ws" 1 auto low
        abi_ws "$ws" "$db" "$fixture/e/stage"
        export GSA_STATE_DIR="$state"
        add_package "$ws" lib "$gsa_meta_any" git
        add_package "$ws" app1 "$gsa_meta_any" git
        add_package "$ws" app2 "$gsa_meta_any" git
        set_topology_record "$ws" lib git "" ""
        set_topology_record "$ws" app1 git "lib" ""
        set_topology_record "$ws" app2 git "app1" ""

        # Hand-built archives: lib ships the provide + soname, the apps link
        # it (the subscription recording's file truth).
        stage="$fixture/e/stage-lib"
        stage_pkginfo "$stage" lib lib "1.0.0-1" 'provides = libx.so=1-64'
        mkdir -p "$stage/usr/lib"
        write_elf64 "$stage/usr/lib/libx.so" libx.so.1
        make_archive "$ws/packages/lib/lib-1.0.0-1-any.pkg.tar.zst" "$stage"
        stage="$fixture/e/stage-app1"
        stage_pkginfo "$stage" app1 app1 "1.0.0-1" 'provides = libapp1.so=1-64'
        mkdir -p "$stage/usr/lib"
        write_elf64 "$stage/usr/lib/libapp1.so" libapp1.so.1 libx.so
        make_archive "$ws/packages/app1/app1-1.0.0-1-any.pkg.tar.zst" "$stage"
        stage="$fixture/e/stage-app2"
        stage_pkginfo "$stage" app2 app2 "1.0.0-1"
        mkdir -p "$stage/usr/lib"
        write_elf64 "$stage/usr/lib/libapp2.so" libapp2.so.2 libapp1.so
        make_archive "$ws/packages/app2/app2-1.0.0-1-any.pkg.tar.zst" "$stage"

        # The installed view (entry mtime IS the install date — created
        # AFTER the archives, so a checked run sees everything as already
        # current and only the wave's skip suppression lets it land).
        e_lib=$(db_entry "$db" lib "0:1.0.0-1" 'libx.so=1-64')
        e_app1=$(db_entry "$db" app1 "0:1.0.0-1" 'libapp1.so=1-64')
        e_app2=$(db_entry "$db" app2 "0:1.0.0-1")
        mkdir -p "$fixture/e/dbfiles/lib/usr/lib" "$fixture/e/dbfiles/app1/usr/lib" \
            "$fixture/e/dbfiles/app2/usr/lib"
        write_elf64 "$fixture/e/dbfiles/lib/usr/lib/libx.so" libx.so.1
        write_elf64 "$fixture/e/dbfiles/app1/usr/lib/libapp1.so" libapp1.so.1 libx.so
        write_elf64 "$fixture/e/dbfiles/app2/usr/lib/libapp2.so" libapp2.so.2 libapp1.so
        db_file "$e_lib" "$fixture/e/dbfiles/lib/usr/lib/libx.so"
        db_file "$e_app1" "$fixture/e/dbfiles/app1/usr/lib/libapp1.so"
        db_file "$e_app2" "$fixture/e/dbfiles/app2/usr/lib/libapp2.so"

        # Pass 1 (force): everything lands and records its `:=`
        # subscriptions against the recorded provider tokens.
        run_engine "$ws" -Uf --state-dir "$state" --config "$ws/pacman.conf" lib app1 app2
        [ "$FIXTURE_RC" = 0 ] || fail "e: pass 1 is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        [ -s "$state/abi/subscriptions" ] \
            || fail "e: pass 1 recorded the := subscriptions (plan §4.1)"
        grep -q '^app1|[^|]*|lib|' "$state/abi/subscriptions" \
            || fail "e: app1 recorded its subscription to lib:" "$state/abi/subscriptions"

        # The move: an `abi-rev=` bump changes lib's token with ZERO provide
        # drift (so no `abi-soname` refusal can fire).
        set_topology_record "$ws" lib git "" "abi-rev=1"
        : >"$GSA_FAKE_PACMAN_LOG"

        # Pass 2 (checked): `gsa -U lib app1` — app2 rides the wave as a
        # computed addition, and the wave lands in ONE transaction.
        run_engine "$ws" -U --state-dir "$state" --config "$ws/pacman.conf" lib app1
        [ "$FIXTURE_RC" = 0 ] || fail "e: pass 2 is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        txn_count=$(grep -c '^pacman ' "$GSA_FAKE_PACMAN_LOG" || true)
        [ "$txn_count" = 1 ] \
            || fail "e: the wave lands in ONE pacman -U (plan §4.5), got $txn_count:" "$GSA_FAKE_PACMAN_LOG"
        txn=$(grep '^pacman ' "$GSA_FAKE_PACMAN_LOG")
        for name in lib-1.0.0-1-any.pkg.tar.zst app1-1.0.0-1-any.pkg.tar.zst app2-1.0.0-1-any.pkg.tar.zst; do
            case "$txn" in
            *"$name"*) ;;
            *) fail "e: the one transaction carries ALL of the wave's archives ($name missing):" "$GSA_FAKE_PACMAN_LOG" ;;
            esac
        done
        # app2 was not named by the user — it joined as the wave's addition.
        vgrep "$FIXTURE_OUTPUT" -Eq '^app2 install ok$' \
            || fail "e: the wave's unnamed member is an install row (wave_heal), got:
$FIXTURE_OUTPUT"
        echo "section e ok"
    )
fi

if want f; then
    # ─── 6. the -Qa/-Qr surfaces (§B.3) ────────────────────────────────────
    (
        set -euo pipefail
        ws="$fixture/f/ws"
        state="$fixture/f/state"
        db="$fixture/f/db"
        make_workspace "$ws" 1 auto low
        abi_ws "$ws" "$db" "$fixture/f/stage"
        mkdir -p "$db"
        export GSA_STATE_DIR="$state"
        add_package "$ws" lib "$gsa_meta_any" git
        add_package "$ws" ghostpkg "$gsa_meta_any" git
        set_topology_record "$ws" lib git "" ""
        set_topology_record "$ws" ghostpkg git "lib" ""

        stage_tree "$fixture/f/stage" lib "1.0.0-1" 'provides = libx.so=1-64'
        stage_tree "$fixture/f/stage" ghostpkg "1.0.0-1"
        run_engine "$ws" -B --no-prefetch --state-dir "$state" lib ghostpkg
        [ "$FIXTURE_RC" = 0 ] || fail "f: the stub build pass is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"

        # (W5: seeded through the real sudo — state/ is engine-owned.)
        /usr/bin/sudo -n mkdir -p "$state/abi"
        {
            printf 'ghostpkg|0:1.0.0-1|lib|recorded-token\n'
        } | /usr/bin/sudo -n tee "$state/abi/subscriptions" >/dev/null

        # -Qa: the token fact, the index's recorded token, and the
        # subscription rows in/out — all derived from the state truth.
        run_engine "$ws" -Qa --state-dir "$state" lib
        [ "$FIXTURE_RC" = 0 ] || fail "f: -Qa is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        vgrep "$(qa_row "$FIXTURE_OUTPUT" lib token)" -Eq \
            '^lib token [^ ]+ source=archive derived=[0-9a-f]+ -$' \
            || fail "f: token row shape (§B.3), got: $FIXTURE_OUTPUT"
        vgrep "$(qa_row "$FIXTURE_OUTPUT" lib index-token)" -Eq \
            '^lib index-token [^ ]+$' \
            || fail "f: index-token row shape (§B.3), got: $FIXTURE_OUTPUT"
        vgrep "$(qa_row "$FIXTURE_OUTPUT" lib subscription-in)" -Eq \
            '^lib subscription-in ghostpkg 0:1\.0\.0-1 recorded-token$' \
            || fail "f: subscription-in row shape (§B.3), got: $FIXTURE_OUTPUT"
        run_engine "$ws" -Qa --state-dir "$state" ghostpkg
        vgrep "$(qa_row "$FIXTURE_OUTPUT" ghostpkg subscription-out)" -Eq \
            '^ghostpkg subscription-out lib recorded-token$' \
            || fail "f: subscription-out row shape (§B.3), got: $FIXTURE_OUTPUT"

        # -Qr: an installed member whose DT_NEEDED resolves to nothing names
        # consumer, member and soname.
        e_ghost=$(db_entry "$db" ghostpkg "0:1.0.0-1")
        mkdir -p "$fixture/f/dbfiles/ghostpkg/usr/lib"
        write_elf64 "$fixture/f/dbfiles/ghostpkg/usr/lib/libghost.so" libghost.so.1 libmissing.so.9
        db_file "$e_ghost" "$fixture/f/dbfiles/ghostpkg/usr/lib/libghost.so"
        run_engine "$ws" -Qr --state-dir "$state"
        [ "$FIXTURE_RC" = 0 ] || fail "f: -Qr is rc 0 (report-only), got $FIXTURE_RC: $FIXTURE_OUTPUT"
        vgrep "$FIXTURE_OUTPUT" -Eq \
            '^unresolved ghostpkg [^ ]*libghost\.so libmissing\.so\.9$' \
            || fail "f: -Qr names the unresolved need (consumer member soname), got:
$FIXTURE_OUTPUT"
        echo "section f ok"
    )
fi

# The real /var/lib/gsa never moved under this fixture (§J.3).
varlib_after=$( (find /var/lib/gsa -printf '%p %s %T@\n' 2>/dev/null || true) | sort | md5sum)
[ "$varlib_before" = "$varlib_after" ] \
    || fail "the real /var/lib/gsa moved under a fixture run (§J.3: state lives behind an override)"
