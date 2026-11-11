#!/usr/bin/env bash
set -euo pipefail

# tests/rendering.sh — the human rendering's COSMETIC contract: the colour
# seam (crates/gsa-cli/src/style.rs) and the aligned `-Q` table.
#
# The machine channel is the stable interface (contract §L.5), so the pins
# here are deliberately split:
#
#   * a pty is the only place the human rendering exists, so every colour
#     case runs `script -qec` with a controlled width, the same driver
#     tests/dashboard.sh uses;
#   * the human `-Q` table must be rectangular — one visible width for every
#     row — and must not exceed the terminal when it is narrow;
#   * `--machine`, and any captured stdout, must stay byte-identical to the
#     pre-table row (`name version abi=<full> built=<full> instances=N`) with
#     zero escape bytes. That is the contract, and it is what every other
#     fixture depends on;
#   * `NO_COLOR=1` must produce exactly the `--color=always` text with the
#     escapes removed, so colour can never be the only difference.
#
# Sections (( subshell )-free — each case is self-contained and runs alone):
#   a. pty + `--color=always`: escapes present, one visible width for every
#      row, the stale row's version in the warn role;
#   b. pty + `NO_COLOR=1`: no escape byte, the same text as (a) stripped, the
#      same uniform width;
#   c. captured `--machine`: today's exact row, no escapes (the stability
#      pin);
#   d. a 40-column pty: no rendered row exceeds 39 visible columns;
#   e. `-Qg` and `-Sl` footers: every `packages` word starts in one column.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"

fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-rendering.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

engine=${GSA_TEST_GSA_BIN:-gsa}
case "$engine" in
/*) ;;
*) engine=$(command -v "$engine") || {
    printf 'gsa-rendering fixture: no engine on PATH\n' >&2
    exit 1
} ;;
esac

fail() {
    printf 'gsa-rendering fixture: %s\n' "$1" >&2
    exit 1
}

# An empty gsa.conf: the auto-read layers must never steer a fixture.
conf="$fixture/gsa.conf"
: >"$conf"

# make_local_db DIR — a scratch pacman local DB behind `pacman-conf DBPath`:
# one short name, one long name (the middle-ellipsis case), both installed.
make_local_db() {
    local db=$1
    mkdir -p "$db/local/foo-1.0-1" \
        "$db/local/a-very-long-package-name-that-must-be-truncated-2.0-1"
    cat >"$db/local/foo-1.0-1/desc" <<'EOF'
%NAME%
foo

%VERSION%
1.0-1

%DESC%
the foo widget
EOF
    : >"$db/local/foo-1.0-1/files"
    cat >"$db/local/a-very-long-package-name-that-must-be-truncated-2.0-1/desc" <<'EOF'
%NAME%
a-very-long-package-name-that-must-be-truncated

%VERSION%
2.0-1

%DESC%
a deliberately overlong name
EOF
    : >"$db/local/a-very-long-package-name-that-must-be-truncated-2.0-1/files"
}

# make_stubs DIR DB — `pacman-conf DBPath` answers the scratch DB.
make_stubs() {
    local dir=$1 db=$2
    mkdir -p "$dir"
    cat >"$dir/pacman-conf" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$db"
EOF
    chmod +x "$dir/pacman-conf"
}

# write_index_row STATE — one §J.4 row whose `built` version is OLDER than
# the installed one, so `-Q` has something to warn about.
write_index_row() {
    local state=$1
    mkdir -p "$state/index"
    printf '%s\n' \
        '{"op":"row","recipe_id":"foo","pkgbase":"foo","pkgnames":["foo"],"version":"0.9-1","archive":"/x/foo-0.9-1-any.pkg.tar.zst","sha256":"00","size":1,"built_at":0,"abi_token":"f811e75af347c90fb6f130104d46cd2fe40ef76349be2bc8b2e894df15b42105","provides":[],"vcs_baseline":"abc123","instance":1}' \
        >>"$state/index/binpkg.jsonl"
}

# run_pty DIR COLS EXTRA_ENV... — run the `-Q` table in a pty of COLS
# columns; stdout+stderr land in $DIR/out.raw. `script(1)` parses its -c
# through the login shell, so the command goes through a wrapper script.
run_pty() {
    local dir=$1 cols=$2 env_block=$3
    shift 3
    cat >"$dir/run.sh" <<EOF
#!/usr/bin/env bash
set -eu
stty cols $cols rows 24
$env_block
exec "$engine" -Q $*
EOF
    chmod +x "$dir/run.sh"
    set +e
    TERM=xterm script -qec "$dir/run.sh" /dev/null >"$dir/out.raw" 2>&1
    local rc=$?
    set -e
    tr -d '\r' <"$dir/out.raw" >"$dir/out.txt"
    [ "$rc" -eq 0 ] || fail "$dir: the engine exited $rc: $(cat "$dir/out.txt")"
}

# One visible width per line, measured the way the engine measures it.
visible_widths() {
    fish -c '
        while read -l line
            echo (string length --visible -- "$line")
        end
    '
}

# assert_one_width FILE LABEL — every row has the same visible width.
assert_one_width() {
    local file=$1 label=$2 widths
    widths=$(visible_widths <"$file" | sort -u)
    [ -n "$widths" ] || fail "$label: rendered nothing"
    if [ "$(wc -l <<<"$widths")" -ne 1 ]; then
        fail "$label: rows differ in visible width: $(tr '\n' ' ' <<<"$widths")"
    fi
}

strip_ansi() {
    sed -e 's/\x1b\[[0-9;]*m//g' "$1"
}

db="$fixture/db"
bin="$fixture/bin"
state="$fixture/state"
make_local_db "$db"
make_stubs "$bin" "$db"
write_index_row "$state"

# ── a. pty + --color=always: colour exists and the table is rectangular ────
mkdir -p "$fixture/a"
run_pty "$fixture/a" 120 \
    "export PATH=\"$bin:\$PATH\" GSA_CONF=\"$conf\" GSA_STATE_DIR=\"$state\"
export NO_COLOR= COLORTERM=truecolor" \
    --color=always
grep -q $'\x1b\[' "$fixture/a/out.txt" \
    || fail "a: --color=always under a pty emitted no escape: $(cat "$fixture/a/out.txt")"
grep -q $'\x1b\[33m' "$fixture/a/out.txt" \
    || fail "a: the stale version (installed 1.0-1, built 0.9-1) is not in the warn role"
assert_one_width "$fixture/a/out.txt" 'a'

# ── b. NO_COLOR: the same text, no escapes, the same uniform width ─────────
mkdir -p "$fixture/b"
run_pty "$fixture/b" 120 \
    "export PATH=\"$bin:\$PATH\" GSA_CONF=\"$conf\" GSA_STATE_DIR=\"$state\"
export NO_COLOR=1"
if grep -q $'\x1b\[' "$fixture/b/out.txt"; then
    fail "b: NO_COLOR=1 still emitted an escape: $(cat "$fixture/b/out.txt")"
fi
assert_one_width "$fixture/b/out.txt" 'b'
strip_ansi "$fixture/a/out.txt" >"$fixture/a/plain"
cmp -s "$fixture/a/plain" "$fixture/b/out.txt" \
    || fail "b: NO_COLOR output is not the coloured output with escapes removed"

# ── c. --machine: today's exact row, zero escapes (the stability pin) ──────
mkdir -p "$fixture/c"
make_workspace "$fixture/c/ws" 1 1 low
GSA_CONF="$conf" GSA_STATE_DIR="$state" PATH="$bin:$PATH" \
    run_engine_user "$fixture/c/ws" -Q --machine
[ "$FIXTURE_RC" -eq 0 ] || fail "c: rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
grep -Fx 'foo 0:1.0-1 abi=f811e75af347c90fb6f130104d46cd2fe40ef76349be2bc8b2e894df15b42105 built=0.9-1 instances=1' \
    <<<"$FIXTURE_OUTPUT" >/dev/null \
    || fail "c: the machine row changed shape: $FIXTURE_OUTPUT"
grep -Fx 'a-very-long-package-name-that-must-be-truncated 0:2.0-1' \
    <<<"$FIXTURE_OUTPUT" >/dev/null \
    || fail "c: a row with no side-car record must stay plain: $FIXTURE_OUTPUT"
if grep -q $'\x1b' <<<"$FIXTURE_OUTPUT"; then
    fail "c: the machine channel carried an escape byte: $FIXTURE_OUTPUT"
fi

# ── c2. --color=always crosses a pipe (it asks for the human rendering),
#        and --machine still wins over it ───────────────────────────────────
mkdir -p "$fixture/c2"
make_workspace "$fixture/c2/ws" 1 1 low
GSA_CONF="$conf" GSA_STATE_DIR="$state" PATH="$bin:$PATH" \
    run_engine_user "$fixture/c2/ws" -Q --color=always
[ "$FIXTURE_RC" -eq 0 ] || fail "c2: rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
grep -q $'\x1b\[' <<<"$FIXTURE_OUTPUT" \
    || fail "c2: --color=always through a pipe emitted no escape"
if ! grep -Eq '^foo +0:1\.0-1 +abi=' < <(sed -e 's/\x1b\[[0-9;]*m//g' <<<"$FIXTURE_OUTPUT"); then
    fail "c2: --color=always did not render the human table row: $FIXTURE_OUTPUT"
fi
GSA_CONF="$conf" GSA_STATE_DIR="$state" PATH="$bin:$PATH" \
    run_engine_user "$fixture/c2/ws" -Q --machine --color=always
grep -Fx 'foo 0:1.0-1 abi=f811e75af347c90fb6f130104d46cd2fe40ef76349be2bc8b2e894df15b42105 built=0.9-1 instances=1' \
    <<<"$FIXTURE_OUTPUT" >/dev/null \
    || fail "c2: --machine must win over --color=always: $FIXTURE_OUTPUT"
if grep -q $'\x1b' <<<"$FIXTURE_OUTPUT"; then
    fail "c2: --machine --color=always carried an escape byte"
fi

# ── d. a 40-column pty: no row exceeds width-1 ────────────────────────────
mkdir -p "$fixture/d"
run_pty "$fixture/d" 40 \
    "export PATH=\"$bin:\$PATH\" GSA_CONF=\"$conf\" GSA_STATE_DIR=\"$state\"
export NO_COLOR=1"
while IFS= read -r width; do
    [ "$width" -le 39 ] || fail "d: a 40-column terminal rendered a $width-column row"
done < <(visible_widths <"$fixture/d/out.txt")

# ── e. the group footers line their counts up ─────────────────────────────
mkdir -p "$fixture/e"
make_workspace "$fixture/e/ws" 1 1 low
add_package "$fixture/e/ws" p1 "" git
add_package "$fixture/e/ws" p2 "" stable
GSA_CONF="$conf" run_engine "$fixture/e/ws" -Qg
[ "$FIXTURE_RC" -eq 0 ] || fail "e: -Qg rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
printf '%s\n' "$FIXTURE_OUTPUT" >"$fixture/e/groups.txt"
column=$(awk '/ packages$/{print index($0, "packages")}' "$fixture/e/groups.txt" | sort -u | wc -l)
[ "$column" -eq 1 ] \
    || fail "e: -Qg puts 'packages' in more than one column: $(cat "$fixture/e/groups.txt")"
GSA_CONF="$conf" run_engine "$fixture/e/ws" -Sl
[ "$FIXTURE_RC" -eq 0 ] || fail "e: -Sl rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
printf '%s\n' "$FIXTURE_OUTPUT" >"$fixture/e/listing.txt"
column=$(awk '/ packages$/{print index($0, "packages")}' "$fixture/e/listing.txt" | sort -u | wc -l)
[ "$column" -eq 1 ] \
    || fail "e: -Sl puts 'packages' in more than one column: $(cat "$fixture/e/listing.txt")"

# ── f. a redirected stdin still fits the TERMINAL's width ─────────────────
# `stty size` read fd 0, so `< /dev/null` (xargs, vim :!, a cron-ish runner)
# laid an 80-column table onto a 40-column screen and every row soft-wrapped
# (blind-review 2026-11-11, keyboard-accessibility).
mkdir -p "$fixture/f"
cat >"$fixture/f/run.sh" <<RUN
#!/usr/bin/env bash
set -eu
stty cols 40 rows 24
export PATH="$bin:\$PATH" GSA_CONF="$conf" GSA_STATE_DIR="$state"
exec "$engine" -Q < /dev/null
RUN
chmod +x "$fixture/f/run.sh"
TERM=xterm script -qec "$fixture/f/run.sh" /dev/null >"$fixture/f/out.raw" 2>&1
tr -d '\r' <"$fixture/f/out.raw" >"$fixture/f/out.txt"
while read -r width; do
    [ "$width" -le 39 ] || fail "f: a redirected stdin rendered a $width-column row on a 40-column pty"
done < <(visible_widths <"$fixture/f/out.txt")

# ── g. TERM=unknown is the dumb rung, not colour + cursor control ─────────
# `sudo` substitutes `unknown` for an UNSET TERM (`env -u TERM sudo …`), and
# a serial console/systemd-run session has exactly that: it used to get the
# full palette and the animated dashboard (blind-review 2026-11-11).
mkdir -p "$fixture/g"
run_pty "$fixture/g" 120 \
    "export PATH=\"$bin:\$PATH\" GSA_CONF=\"$conf\" GSA_STATE_DIR=\"$state\"
export TERM=unknown" 
if grep -q $'\x1b\[' "$fixture/g/out.txt"; then
    fail "g: TERM=unknown emitted an escape (colour or cursor control): $(cat "$fixture/g/out.txt")"
fi
assert_one_width "$fixture/g/out.txt" 'g (TERM=unknown)'
