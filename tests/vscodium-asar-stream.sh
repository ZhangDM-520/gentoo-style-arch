#!/usr/bin/env bash
set -euo pipefail

# vscodium-insiders-git node_modules.asar streaming fixture.
#
# build() patches the vscode clone's build/lib/asar.ts to emit the asar
# archive as a chunk stream instead of ONE concatenated buffer: Node's
# fs.write caps a single write at INT32_MAX bytes and vinyl-fs writes a
# Buffer-valued VinylFile with exactly one fs.write(...), so the 2.83GB
# node_modules.asar died with ERR_OUT_OF_RANGE at the min-packing step
# (2026-10-21, two strikes, deterministic). This fixture pins:
#
#   - the recipe's node-modules-asar-stream.diff applies cleanly to the
#     pinned upstream file shape (tests/assets/vscodium-asar.ts.orig);
#   - the patched output emits a Readable stream and no longer builds the
#     archive with Buffer.concat in the flush;
#   - the diff's checksum is the one the recipe's sha256sums declares
#     (recipe↔patch anchoring, rule 18).
#
# The end-to-end proof is the next real build writing node_modules.asar.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
recipe="$root/packages/git/vscodium-insiders-git"
diff_file="$recipe/node-modules-asar-stream.diff"
asset="$root/tests/assets/vscodium-asar.ts.orig"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-vscodium-asar.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    printf 'vscodium asar-stream fixture: %s\n' "$1" >&2
    exit 1
}

# ─── 1. the patch applies cleanly to the pinned upstream shape ────────────
mkdir -p "$tmp/build/lib"
cp "$asset" "$tmp/build/lib/asar.ts"
( cd "$tmp" && patch -p1 --silent <"$diff_file" ) ||
    fail "node-modules-asar-stream.diff no longer applies to the pinned asar.ts shape"

patched="$tmp/build/lib/asar.ts"

# ─── 2. the flush streams, it no longer concatenates ──────────────────────
grep -q "import { Readable } from 'stream';" "$patched" ||
    fail "the patched file lost the Readable import"
grep -q 'new Readable({' "$patched" ||
    fail "the patched file does not emit a Readable stream"
grep -q 'Buffer.concat(out)' "$patched" &&
    fail "the patched flush still builds the archive with Buffer.concat"
grep -q 'out.splice(0)' "$patched" ||
    fail "the patched flush no longer takes ownership of the chunk list"

# ─── 3. the recipe declares exactly this diff (anchored checksum) ─────────
declared=$(bash -c "source '$recipe/PKGBUILD'
    for i in \"\${!source[@]}\"; do
        [[ \${source[i]} == node-modules-asar-stream.diff ]] && printf '%s\n' \"\${sha256sums[i]}\"
    done")
actual=$(sha256sum "$diff_file" | cut -d' ' -f1)
[[ $declared == "$actual" ]] ||
    fail "sha256sums drifts from node-modules-asar-stream.diff (declared ${declared:-MISSING}, actual $actual)"

printf 'vscodium asar-stream fixture: PASS\n'
