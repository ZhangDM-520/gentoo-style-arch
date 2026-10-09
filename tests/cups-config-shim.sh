#!/usr/bin/env bash
# tests/cups-config-shim.sh — pin lib/cups-config's output shape to upstream
# cups 2.4 cups-config.in (extracted from the cups mirror at v2.4.11).
#
# The defect class (2026-10-10 run #102 libppd wall): configure scripts
# combine flags in ONE invocation, e.g. libppd's
#   CUPS_LIBS=`$CUPSCONFIG --image --libs`
# upstream cups-config echoes one line per option and --image is a no-op
# ("Do nothing"), so that capture yields exactly the --libs line. A shim
# that prints anything for --image embeds a newline in a Makefile variable
# and the orphan next line dies later with "missing separator".
#
# Non-mutating: reads lib/cups-config only, asserts its stdout/stderr/rc.

set -u
root=$(cd "$(dirname "$0")/.." && pwd)
shim="$root/lib/cups-config"

fail() { echo "cups-config-shim: $*" >&2; exit 1; }

[ -f "$shim" ] || fail "$shim missing"

# 1. --image --libs is one line: just the --libs value (upstream ignores --image)
out=$(sh "$shim" --image --libs 2>/dev/null) || fail "--image --libs exited non-zero"
[ "$out" = "-lcups" ] || fail "--image --libs must print exactly '-lcups' (one line), got: [$out]"

# 2. --image alone prints NOTHING (upstream: "Do nothing"); exit 0
out=$(sh "$shim" --image 2>/dev/null) || fail "--image exited non-zero"
[ -z "$out" ] || fail "--image must print nothing (upstream no-op), got: [$out]"

# 3. --libs alone is the same single line
out=$(sh "$shim" --libs 2>/dev/null) || fail "--libs exited non-zero"
[ "$out" = "-lcups" ] || fail "--libs must print exactly '-lcups', got: [$out]"

# 4. an unknown option is a hard error, not a silent empty capture
if sh "$shim" --nonsense >/dev/null 2>&1; then
    fail "unknown option must exit non-zero"
fi

echo "cups-config-shim: all assertions passed" >&2
