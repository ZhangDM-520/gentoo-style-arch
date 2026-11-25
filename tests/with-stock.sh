#!/usr/bin/env bash
set -euo pipefail

# Issue #6 — `--with`: a stock consumer of a moved soname joins the ONE
# install transaction.
#
# `abi-soname` coverage is transaction membership (`tx_names`) or in-run
# repair (`later_installs`). An installed OUT-OF-TREE package is in neither:
# `-S` transactions carry only engine-built archives, and `-U` needs
# consumer archives that cannot exist before the provider installs. Healing
# `libjxl.so.0.12 -> 0.13` was therefore impossible through the engine —
# the two gates blocked each other (observed 2026-11-20).
#
# `--with PKG` resolves a stock name to the repo archive pacman would
# install and admits it to the same `pacman -U` as the provider, so the old
# consumer file and the old provider file disappear in one atomic step.
# Its own bytes are verified (`with-unresolved`), so membership is never an
# assertion.
#
# Pinned here:
#   A. without `--with`, the refusal stands AND names the exact repair set
#      (`abi-stock-upgrade <name> <installed-ver> <repo-ver>` + one note);
#   B. `--with` puts provider and stock archive in ONE `pacman -U` argv and
#      the run succeeds;
#   C. a name the repos do not carry refuses BEFORE anything builds;
#   D. a name whose archive cannot be fetched refuses, naming the download;
#   E. the flag is `-S`-only: `-B`/`-U` refuse it as a usage error (rc 2).
#
# Synthetic workspace, PATH stubs and a fabricated local DB only; nothing
# real is built, downloaded or installed.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"

fail() {
    printf 'with-stock fixture: %s\n' "$1" >&2
    exit 1
}

if [ -z "${GSA_TEST_GSA_BIN:-}" ]; then
    GSA_TEST_GSA_BIN=$(command -v gsa) || {
        printf 'contract §L.10: no installed gsa on PATH — install gsa-pm, or set GSA_TEST_GSA_BIN explicitly\n' >&2
        exit 1
    }
fi
[ -x "$GSA_TEST_GSA_BIN" ] || fail "the engine under test is not executable: $GSA_TEST_GSA_BIN"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-with-stock.XXXXXX")
if [[ -n ${GSA_KEEP_TMP:-} ]]; then
    trap 'printf "with-stock: kept %s\n" "$tmp" >&2' EXIT
else
    trap '/usr/bin/sudo -n rm -rf -- "$tmp" 2>/dev/null || rm -rf -- "$tmp" 2>/dev/null || true' EXIT
fi

ws="$tmp/ws"
make_workspace "$ws" 1 2 low
add_package "$ws" abipkg
chmod +x "$ws/bin" 2>/dev/null || true

# ── stubs ────────────────────────────────────────────────────────────────
# makepkg: the provider's archive declares the MOVED provide and ships the
# new generation's library path (the transaction's shipped bytes).
cat >"$ws/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -eu
id=$(basename "$PWD")
printf 'BUILD %s\n' "$id" >>"${GSA_FAKE_MAKEPKG_LOG:?}"
stage="$PWD/.stage-$id"
mkdir -p "$stage"
{
    printf 'pkgbase = %s\n' "$id"
    printf 'pkgname = %s\n' "$id"
    printf 'pkgver = 1.0.0-1\n'
    printf 'arch = any\n'
    if [ "$id" = abipkg ]; then
        printf 'provides = libfoo.so=2-64\n'
    fi
} >"$stage/.PKGINFO"
if [ "$id" = abipkg ]; then
    mkdir -p "$stage/usr/lib"
    : >"$stage/usr/lib/libfoo.so.2"
fi
tar --zstd -cf "$PWD/$id-1.0.0-1-any.pkg.tar.zst" -C "$stage" .
rm -rf "$stage"
EOF
chmod +x "$ws/bin/makepkg"

# pacman: answers `-Si` from a one-package repo, refuses `-Sw` (nothing may
# be downloaded in a fixture), logs every argv, accepts `-U`.
cat >"$ws/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'pacman %s\n' "$*" >>"${GSA_FAKE_PACMAN_LOG:?}"
case " $* " in
*' -Si '*)
    # Real pacman prints a block per KNOWN name and exits NON-ZERO when any
    # named package is unknown, so the hint's reader must take the blocks it
    # got instead of discarding all of them (round-2 review 2026-11-20).
    rc=0
    after=0
    for arg in "$@"; do
        if ((after)); then
            case $arg in
            -*) continue ;;
            esac
            if [ "$arg" = stock-pin ]; then
                # The repo's current version follows the case under test: a
                # sibling file pins it (the cache and the answer must agree,
                # or the hint resolves an archive the cache does not hold).
                version=2.0-1
                vf="${GSA_FAKE_PACMAN_LOG%/*}/stock-version"
                [ -r "$vf" ] && read -r version <"$vf"
                printf 'Repository      : core\n'
                printf 'Name            : stock-pin\n'
                printf 'Version         : %s\n' "$version"
                printf 'Architecture    : x86_64\n'
            else
                printf "error: package '%s' was not found\n" "$arg" >&2
                rc=1
            fi
            continue
        fi
        if [ "$arg" = -Si ]; then after=1; fi
    done
    exit $rc
    ;;
*' -Sw '*)
    printf 'pacman: fixture: nothing may be downloaded here\n' >&2
    exit 1
    ;;
esac
exit 0
EOF
chmod +x "$ws/bin/pacman"
stub_sudo "$ws"

# pacman-conf: the fabricated local DB, never the host's.
mkdir -p "$ws/db/local"
cat >"$ws/bin/pacman-conf" <<EOF
#!/usr/bin/env bash
set -u
for arg in "\$@"; do
    case \$arg in
    DBPath)
        printf '%s\n' "$ws/db"
        exit 0
        ;;
    CacheDir)
        printf '%s/\n' "$tmp/cache"
        exit 0
        ;;
    esac
done
exit 1
EOF
chmod +x "$ws/bin/pacman-conf"

# The installed world: the provider still at the OLD generation, and the
# out-of-tree consumer that pins it.
mkdir -p "$ws/db/local/abipkg-1.0.0-1" "$ws/db/local/stock-pin-1.0-1"
cat >"$ws/db/local/abipkg-1.0.0-1/desc" <<'EOF'
%NAME%
abipkg

%VERSION%
1.0.0-1

%PROVIDES%
libfoo.so=1-64
EOF
printf '%%FILES%%\nusr/lib/libfoo.so.1\n' >"$ws/db/local/abipkg-1.0.0-1/files"
cat >"$ws/db/local/stock-pin-1.0-1/desc" <<'EOF'
%NAME%
stock-pin

%VERSION%
1.0-1

%DEPENDS%
libfoo.so=1-64
EOF
printf '%%FILES%%\nusr/bin/stock-pin\n' >"$ws/db/local/stock-pin-1.0-1/files"

# The repo archive `--with` resolves: its own links must fit the system the
# transaction produces (DT_NEEDED the NEW generation), which is exactly what
# a real repo rebuild carries.
cache="$tmp/cache"
mkdir -p "$cache" "$tmp/stock-stage/usr/lib"
printf 'int gsa_stock_anchor;\n' |
    cc -shared -x c - -Wl,-soname,libstock.so -o "$tmp/stock-stage/usr/lib/libstock.so"
bindir="$tmp/stock-bin/usr/bin"
mkdir -p "$bindir"
printf 'int main(void){return 0;}\n' |
    cc -x c - -Wl,--no-as-needed -L"$tmp/stock-stage/usr/lib" -l:libstock.so \
        -o "$bindir/stock-pin"
{
    printf 'pkgbase = stock-pin\n'
    printf 'pkgname = stock-pin\n'
    printf 'pkgver = 2.0-1\n'
    printf 'arch = x86_64\n'
} >"$tmp/stock-stage/.PKGINFO"
tar --zstd -cf "$cache/stock-pin-2.0-1-x86_64.pkg.tar.zst" -C "$tmp/stock-stage" .

export GSA_FAKE_MAKEPKG_LOG="$ws/makepkg.log"
export GSA_FAKE_PACMAN_LOG="$ws/pacman.log"
export GSA_FAKE_SUDO_LOG="$ws/sudo.log"
export GSA_STATE_DIR="$ws/state"
export GSA_CONF_DIR="$tmp/conf"
mkdir -p "$GSA_CONF_DIR"
: >"$GSA_FAKE_MAKEPKG_LOG"
: >"$GSA_FAKE_PACMAN_LOG"
: >"$GSA_FAKE_SUDO_LOG"

run() {
    local status=0
    FIXTURE_OUTPUT=$(cd "$ws" && /usr/bin/sudo -n env GSA_BUILD_HISTORY=off \
        "PATH=$ws/bin:$PATH" \
        "GSA_STATE_DIR=$GSA_STATE_DIR" "GSA_CONF_DIR=$GSA_CONF_DIR" \
        "GSA_FAKE_MAKEPKG_LOG=$GSA_FAKE_MAKEPKG_LOG" \
        "GSA_FAKE_PACMAN_LOG=$GSA_FAKE_PACMAN_LOG" \
        "GSA_FAKE_SUDO_LOG=$GSA_FAKE_SUDO_LOG" \
        "$GSA_TEST_GSA_BIN" "$@" 2>&1) || status=$?
    FIXTURE_RC=$status
}

# ── C. a name the repos do not carry refuses before anything builds ──────
# The stub answers `-Si` for `stock-pin` only; everything else is an
# unknown-target failure, which is a startup refusal (rc 3).
run -S --leaf --no-sync --config "$ws/pacman.conf" abipkg --with nosuchpkg
[[ $FIXTURE_RC -eq 3 ]] ||
    fail "an unresolvable --with name did not refuse rc 3 (got $FIXTURE_RC):
$FIXTURE_OUTPUT"
[[ $FIXTURE_OUTPUT == *"cannot resolve --with nosuchpkg"* ]] ||
    fail "the unresolvable name is not named: $FIXTURE_OUTPUT"
[[ ! -s $GSA_FAKE_MAKEPKG_LOG ]] ||
    fail "a build ran despite an unresolvable --with name:
$(cat "$GSA_FAKE_MAKEPKG_LOG")"

# ── D. an archive that cannot be fetched refuses, naming the download ────
mv "$cache/stock-pin-2.0-1-x86_64.pkg.tar.zst" "$tmp/stock-archive"
run -S --leaf --no-sync --config "$ws/pacman.conf" abipkg --with stock-pin
mv "$tmp/stock-archive" "$cache/stock-pin-2.0-1-x86_64.pkg.tar.zst"
[[ $FIXTURE_RC -eq 3 ]] ||
    fail "an unfetchable --with archive did not refuse rc 3 (got $FIXTURE_RC):
$FIXTURE_OUTPUT"
[[ $FIXTURE_OUTPUT == *"cannot download --with stock-pin"* ]] ||
    fail "the failed download is not named: $FIXTURE_OUTPUT"
[[ $FIXTURE_OUTPUT == *"-Sw"* || $(cat "$GSA_FAKE_PACMAN_LOG") == *"-Sw"* ]] ||
    fail "no pacman -Sw was attempted: $FIXTURE_OUTPUT
$(cat "$GSA_FAKE_PACMAN_LOG")"

# ── A. without --with: the refusal names the exact repair set ────────────
: >"$GSA_FAKE_PACMAN_LOG"
: >"$GSA_FAKE_MAKEPKG_LOG"
run -S --leaf --no-sync --config "$ws/pacman.conf" abipkg
[[ $FIXTURE_RC -eq 3 ]] ||
    fail "the stock-pinned move did not refuse rc 3 (got $FIXTURE_RC):
$FIXTURE_OUTPUT"
[[ $FIXTURE_OUTPUT == *"install-refused abi-soname"* ]] ||
    fail "no abi-soname refusal: $FIXTURE_OUTPUT"
# The step's refusal ROWS collapse to the first reason in the record, so the
# repair is carried by notes (and by the typed `abi-stock-upgrade` row the
# step returns): both name the exact member and its repo version.
[[ $FIXTURE_OUTPUT == *"gsa: note: stock upgrade available: stock-pin 1.0-1 -> 2.0-1"* ]] ||
    fail "the verified repair hint is missing or drifted: $FIXTURE_OUTPUT"
[[ $FIXTURE_OUTPUT == *"transact the stock upgrades with --with stock-pin"* ]] ||
    fail "the repair note is missing: $FIXTURE_OUTPUT"
[[ $(cat "$GSA_FAKE_PACMAN_LOG") != *"-U"* ]] ||
    fail "a refused plan still transacted:
$(cat "$GSA_FAKE_PACMAN_LOG")"

# ── B. --with: one transaction carries both archives ─────────────────────
: >"$GSA_FAKE_PACMAN_LOG"
: >"$GSA_FAKE_MAKEPKG_LOG"
run -S --leaf --no-sync --config "$ws/pacman.conf" abipkg --with stock-pin
[[ $FIXTURE_RC -eq 0 ]] ||
    fail "--with did not heal the move (got $FIXTURE_RC):
$FIXTURE_OUTPUT"
[[ $FIXTURE_OUTPUT == *"gsa: note: with stock-pin 2.0-1"* ]] ||
    fail "the resolved member is not announced: $FIXTURE_OUTPUT"
[[ $FIXTURE_OUTPUT == *"joins the transaction only where the ABI gate needs it"* ]] ||
    fail "the membership rule is not stated: $FIXTURE_OUTPUT"
# The stock archive's own install is announced beside the built one: bytes
# the run did not build are never an unaccounted write.
[[ $FIXTURE_OUTPUT == *"install decision=install pkg=stock-pin version=0:2.0-1"* && $FIXTURE_OUTPUT == *"reason=with"* ]] ||
    fail "the stock member's install is not announced: $FIXTURE_OUTPUT"
mapfile -t u_lines < <(grep -- ' -U ' "$GSA_FAKE_PACMAN_LOG" || true)
((${#u_lines[@]} == 1)) ||
    fail "expected exactly one pacman -U transaction, got ${#u_lines[@]}:
$(cat "$GSA_FAKE_PACMAN_LOG")"
line=${u_lines[0]}
[[ $line == *"abipkg-1.0.0-1-any.pkg.tar.zst"* ]] ||
    fail "the built provider is not in the transaction: $line"
[[ $line == *"stock-pin-2.0-1-x86_64.pkg.tar.zst"* ]] ||
    fail "the stock archive is not in the SAME transaction: $line"
[[ $FIXTURE_OUTPUT != *"install-refused"* ]] ||
    fail "a covered member still refused: $FIXTURE_OUTPUT"
[[ $FIXTURE_OUTPUT != *"stock upgrade available"* ]] ||
    fail "a healed move still advertised a repair: $FIXTURE_OUTPUT"

# ── D2. a stock archive pinning the removed generation refuses ───────────
# The archive's own `depend = libfoo.so=1-64` would make pacman refuse the
# transaction in raw noise; the plan refuses first, naming the pin.
mkdir -p "$tmp/stock-pin-stage/usr/lib" "$tmp/stock-pin-cache"
cp "$tmp/stock-stage/usr/lib/libstock.so" "$tmp/stock-pin-stage/usr/lib/libstock.so"
{
    printf 'pkgbase = stock-pin\n'
    printf 'pkgname = stock-pin\n'
    printf 'pkgver = 2.0-1\n'
    printf 'arch = x86_64\n'
    printf 'depend = libfoo.so=1-64\n'
} >"$tmp/stock-pin-stage/.PKGINFO"
tar --zstd -cf "$tmp/stock-pin-cache/stock-pin-2.0-1-x86_64.pkg.tar.zst" \
    -C "$tmp/stock-pin-stage" .
# `pacman-conf CacheDir` answers the shared cache; point it at this one run.
sed -i "s|printf '%s/\\\\n' \"$tmp/cache\"|printf '%s/\\\\n' \"$tmp/stock-pin-cache\"|" "$ws/bin/pacman-conf"
run -S --leaf --no-sync --config "$ws/pacman.conf" abipkg --with stock-pin
cat >"$ws/bin/pacman-conf" <<EOF
#!/usr/bin/env bash
set -u
for arg in "\$@"; do
    case \$arg in
    DBPath)
        printf '%s\n' "$ws/db"
        exit 0
        ;;
    CacheDir)
        printf '%s/\n' "$tmp/cache"
        exit 0
        ;;
    esac
done
exit 1
EOF
chmod +x "$ws/bin/pacman-conf"
[[ $FIXTURE_RC -eq 3 ]] ||
    fail "a pin on the removed generation did not refuse (got $FIXTURE_RC):
$FIXTURE_OUTPUT"
[[ $FIXTURE_OUTPUT == *"with-unresolved"* && $FIXTURE_OUTPUT == *"pin libfoo.so=1-64"* ]] ||
    fail "the stale pin is not named: $FIXTURE_OUTPUT"

# ── E. the flag is `-S`-only ─────────────────────────────────────────────
run -B --leaf --with stock-pin abipkg
[[ $FIXTURE_RC -eq 2 ]] ||
    fail "-B accepted --with (want usage rc 2, got $FIXTURE_RC):
$FIXTURE_OUTPUT"
run -Su --with stock-pin
[[ $FIXTURE_RC -eq 2 ]] ||
    fail "-Su accepted --with (want usage rc 2, got $FIXTURE_RC):
$FIXTURE_OUTPUT"
[[ $FIXTURE_OUTPUT == *"--with applies to a -S install"* ]] ||
    fail "the -Su refusal does not name the flag: $FIXTURE_OUTPUT"
run -U --with stock-pin "$cache/stock-pin-2.0-1-x86_64.pkg.tar.zst"
[[ $FIXTURE_RC -eq 2 ]] ||
    fail "-U accepted --with (want usage rc 2, got $FIXTURE_RC):
$FIXTURE_OUTPUT"

# ── F. one unknown stranded name never silences the others' hint ─────────
# `pacman -Si known unknown` prints the known block and exits non-zero. An
# out-of-tree consumer the repos do not carry (AUR/local) must not erase the
# only repair the operator can see for its sibling (round-2 review
# 2026-11-20).
mkdir -p "$ws/db/local/stock-pin2-1.0-1"
cat >"$ws/db/local/stock-pin2-1.0-1/desc" <<'EOF'
%NAME%
stock-pin2

%VERSION%
1.0-1

%DEPENDS%
libfoo.so=1-64
EOF
printf '%%FILES%%\nusr/bin/stock-pin2\n' >"$ws/db/local/stock-pin2-1.0-1/files"
: >"$GSA_FAKE_PACMAN_LOG"
: >"$GSA_FAKE_MAKEPKG_LOG"
run -S --leaf --no-sync --config "$ws/pacman.conf" abipkg
[[ $FIXTURE_RC -eq 3 ]] ||
    fail "two stranded pinners did not refuse rc 3 (got $FIXTURE_RC):
$FIXTURE_OUTPUT"
[[ $(cat "$GSA_FAKE_PACMAN_LOG") == *"-Si stock-pin stock-pin2"* ]] ||
    fail "the hint did not read both stranded names in one -Si:
$(cat "$GSA_FAKE_PACMAN_LOG")"
[[ $FIXTURE_OUTPUT == *"gsa: note: stock upgrade available: stock-pin 1.0-1 -> 2.0-1"* ]] ||
    fail "an unknown sibling silenced the known repair hint:
$FIXTURE_OUTPUT"
[[ $FIXTURE_OUTPUT != *"stock upgrade available: stock-pin2"* ]] ||
    fail "a name the repos do not carry grew a hint: $FIXTURE_OUTPUT"
[[ $FIXTURE_OUTPUT == *"transact the stock upgrades with --with stock-pin"* ]] ||
    fail "the advice does not name exactly the transactable member: $FIXTURE_OUTPUT"
rm -rf "$ws/db/local/stock-pin2-1.0-1"

# ── G. `--with a,a` names ONE member ────────────────────────────────────
# A duplicate target is an ALPM error, and the member would be announced
# and registered twice.
: >"$GSA_FAKE_PACMAN_LOG"
: >"$GSA_FAKE_MAKEPKG_LOG"
run -S --leaf --no-sync --config "$ws/pacman.conf" abipkg --with stock-pin,stock-pin
[[ $FIXTURE_RC -eq 0 ]] ||
    fail "a repeated --with name did not heal the move (got $FIXTURE_RC):
$FIXTURE_OUTPUT"
u_line=$(grep -- ' -U ' "$GSA_FAKE_PACMAN_LOG" || true)
[[ -n $u_line ]] || fail "no pacman -U ran:
$(cat "$GSA_FAKE_PACMAN_LOG")"
[[ $(grep -o 'stock-pin-2.0-1-x86_64.pkg.tar.zst' <<<"$u_line" | wc -l) -eq 1 ]] ||
    fail "a repeated name reached the transaction twice: $u_line"
[[ $(grep -c 'install decision=install pkg=stock-pin ' <<<"$FIXTURE_OUTPUT") -eq 1 ]] ||
    fail "a repeated name was announced twice: $FIXTURE_OUTPUT"

# ── H. an installed version AHEAD of the repo is not an upgrade ──────────
# A local/testing build newer than the repo would be silently DOWNGRADED by
# following the hint, so no hint is owed at all (round-2 spec review).
sed -i 's|^1\.0-1$|3.0-1|' "$ws/db/local/stock-pin-1.0-1/desc"
: >"$GSA_FAKE_PACMAN_LOG"
run -S --leaf --no-sync --config "$ws/pacman.conf" abipkg
sed -i 's|^3\.0-1$|1.0-1|' "$ws/db/local/stock-pin-1.0-1/desc"
[[ $FIXTURE_RC -eq 3 ]] ||
    fail "a stranded move did not refuse rc 3 (got $FIXTURE_RC):
$FIXTURE_OUTPUT"
[[ $FIXTURE_OUTPUT != *"stock upgrade available"* ]] ||
    fail "a downgrade was advertised as an upgrade: $FIXTURE_OUTPUT"
[[ $FIXTURE_OUTPUT != *"transact the stock upgrades"* ]] ||
    fail "a downgrade was offered to --with: $FIXTURE_OUTPUT"

# ── I. an archive `--with` would refuse is never advertised ──────────────
# The hint's "verified" is the `--with` acceptance itself: a repo archive
# whose OWN links the post-transaction system cannot satisfy must be named
# without the row and without the advice (round-3 review 2026-11-20).
mkdir -p "$tmp/stock-unfit/usr/bin" "$tmp/stock-unfit-cache"
printf 'int gsa_unrelated;\n' |
    cc -shared -x c - -Wl,-soname,libunrelated.so.9 -o "$tmp/libunrelated.so.9"
printf 'int main(void){return 0;}\n' |
    cc -x c - -Wl,--no-as-needed -L"$tmp" -l:libunrelated.so.9 \
        -o "$tmp/stock-unfit/usr/bin/stock-pin"
printf 'pkgbase = stock-pin\npkgname = stock-pin\npkgver = 3.0-1\narch = x86_64\n' \
    >"$tmp/stock-unfit/.PKGINFO"
tar --zstd -cf "$tmp/stock-unfit-cache/stock-pin-3.0-1-x86_64.pkg.tar.zst" \
    -C "$tmp/stock-unfit" .
sed -i "s|printf '%s/\\\\n' \"$tmp/cache\"|printf '%s/\\\\n' \"$tmp/stock-unfit-cache\"|" "$ws/bin/pacman-conf"
printf '3.0-1\n' >"$ws/stock-version"
: >"$GSA_FAKE_PACMAN_LOG"
run -S --leaf --no-sync --config "$ws/pacman.conf" abipkg
rm -f "$ws/stock-version"
[[ $FIXTURE_RC -eq 3 ]] ||
    fail "an unfitting upgrade did not refuse rc 3 (got $FIXTURE_RC):
$FIXTURE_OUTPUT"
[[ $FIXTURE_OUTPUT == *"stock upgrade available: stock-pin 1.0-1 -> 3.0-1"* ]] ||
    fail "the version difference is not named: $FIXTURE_OUTPUT"
[[ $FIXTURE_OUTPUT == *"does not fit this transaction"* ]] ||
    fail "an unfit archive is not distinguished from an unfetched one: $FIXTURE_OUTPUT"
[[ $FIXTURE_OUTPUT != *"transact the stock upgrades"* ]] ||
    fail "an archive --with would refuse was still advised: $FIXTURE_OUTPUT"
cat >"$ws/bin/pacman-conf" <<EOF
#!/usr/bin/env bash
set -u
for arg in "\$@"; do
    case \$arg in
    DBPath)
        printf '%s\n' "$ws/db"
        exit 0
        ;;
    CacheDir)
        printf '%s/\n' "$tmp/cache"
        exit 0
        ;;
    esac
done
exit 1
EOF
chmod +x "$ws/bin/pacman-conf"

printf 'with-stock fixture: ok\n'
