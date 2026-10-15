#!/usr/bin/env bash
set -euo pipefail

# `gsa -Mccc` (contract §B.7, prune strength 3) deletes the downloads makepkg
# leaves in a recipe directory, and the root .gitignore denies the same set.
# When the two drifted, a commit sweep picked up 36 MB of upstream archives
# (2026-09-20: ten files under `libreoffice-fresh`) because the cleanup matched
# only `*.tar.*` and `*.whl`. This fixture pins the pairing from the engine
# side: every archive type the ignore file denies is deleted, and nothing else
# is. The engine derives its download set from the root `.gitignore` itself
# (crates/gsa-maint/src/prune.rs `download_patterns`: every `*.<ext>` rule,
# matched against URL-backed source names only), so the pairing is pinned
# behaviourally: one URL-backed probe per rule must land in the `-Mccc` target
# rendering and be pruned by the apply run.
#
# It also pins the two properties that make a broad list safe:
#   * only URL-backed entries are targets — a local patch, keyring or hook in the
#     recipe directory is somebody's committed asset, and `tests/recipe-sources.sh`
#     would fail if it went missing;
#   * a symlinked source is deliberate sharing, so -Mccc keeps it and reports it
#     (`keep symlink` target row).
#
# The report itself is part of the contract for the same reason: a pipe is the
# documented way to read this engine (the dashboard is only for a terminal), and
# a maintenance sweep has to be able to see *what* -Mccc is about to delete
# before it agrees. The ask-first path pins that: a bare `gsa -Mccc` prints its
# full target list and stops rc 3 (`confirmation-required`) with nothing
# deleted; `--noconfirm` applies exactly that list.
#
# Flip notes (docs/gsa-fixture-migration.md row `tests/cleanup-extensions.sh`):
# argv `-ccc` flips to `gsa -Mccc` (§B.7). The R-1 fish-source grep of
# `_DOWNLOAD_ARCHIVE_EXTS` (§6 R-1) retires with NO source-shape replacement:
# the engine keeps no separate extension list to drift — the set IS the root
# `.gitignore` `*.<ext>` rules — so the old two-file pairing collapses into the
# per-rule probe assertions (every rule has a pruned URL-backed probe; nothing
# else is touched). Prose byte-pins (`NUCLEAR`, `preserved`, `symlink(s)
# preserved`) retire as rendering (§L.3/§6): their meanings re-pin from the
# target rows — the rendering names every pruned file (`prune`/`pruned`
# classes) and reports a kept symlink as `keep symlink`; the pipe-visible
# meaning is the captured run output itself (run_engine always captures
# through a pipe).
# DEVIATION (inventory pins :85-100: a symlinked staging dir survives -ccc,
# "Symlinks are preserved and reported, not deleted"): the engine's documented
# policy (crates/gsa-maint/src/prune.rs) classifies a symlinked staging entry
# as `prune staging` and UNLINKS the link — `rm -rf` semantics on a symlinked
# tree, never recursed into — while a symlinked archive/clone/download earns
# `keep symlink`. The deliberate-sharing meaning keeps (the VCS clone symlink
# survives and is reported); the staging link's survival re-pins as the
# never-followed half (§B.7 "never followed"): its target tree is untouched.
# The engine's `-Mccc` is also cumulative per §B.7 ("additionally"): it removes
# built archives with strength 2 first — today's fish `-ccc` kept them.
#
# Nothing here touches the real repository: the workspace is synthetic, under
# $TMPDIR, and the engine's state root is redirected under it.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-cleanup-fixture.XXXXXX")
trap '/usr/bin/sudo -n rm -rf -- "$fixture" 2>/dev/null || rm -rf -- "$fixture" 2>/dev/null || true' EXIT

fail() {
    printf 'cleanup-extensions fixture: %s\n' "$1" >&2
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

make_workspace "$fixture" auto auto xhigh
export GSA_STATE_DIR="$fixture/state"

# The engine's download set is the workspace root's `.gitignore` rule set —
# copy the real one so the pairing below is the real repo's pairing.
cp "$root/.gitignore" "$fixture/.gitignore"

# One URL-backed probe source per `*.<ext>` rule the real root .gitignore
# carries (derived from the file, never from engine source): each must be a
# cleanup target. `*` inside an extension is a glob slot — fill it with `x`.
probe_names=()
while IFS= read -r rule; do
    ext=${rule#\*.}
    ext=${ext//\*/x}
    probe_names+=("probe-$RANDOM$RANDOM.$ext")
done < <(grep -E '^\*\.' "$root/.gitignore")

# The demo recipe's URL-backed sources: the original download families, a name
# no rule matches (keepme.txt), the shared VCS clone and the local assets.
src_urls=(
    'https://example.invalid/thing-1.0.tar.xz'
    'https://example.invalid/bundle-2.0.tgz'
    'https://example.invalid/art-3.0.zip'
    'https://example.invalid/tool-4.0.jar'
    'https://example.invalid/font-5.0.ttf'
    'https://example.invalid/wheel-6.0-py3-none-any.whl'
    'https://example.invalid/plain-7.0.tar'
    'https://example.invalid/keepme.txt'
    'git+https://example.invalid/shared.git'
    'local.patch'
    'local.patch.sig'
)
for name in "${probe_names[@]}"; do
    src_urls+=("https://example.invalid/$name")
done
demo_meta='pkgver=1.0'
demo_meta+=$'\n''source=('
for url in "${src_urls[@]}"; do
    demo_meta+="'$url' "
done
demo_meta+=')'
add_package "$fixture" demo "$demo_meta"

# A stub that behaves like a passwordless `sudo`: the engine's prune never
# escalates; the stub only keeps a stray call off the host.
stub_sudo "$fixture"

pkgdir="$fixture/packages/demo"

# The downloads, named exactly as makepkg's SRCDEST would leave them, plus the
# companion files that travel with an archive.
for f in thing-1.0.tar.xz bundle-2.0.tgz art-3.0.zip tool-4.0.jar \
    font-5.0.ttf wheel-6.0-py3-none-any.whl plain-7.0.tar keepme.txt \
    thing-1.0.tar.xz.sig thing-1.0.tar.xz.asc thing-1.0.tar.xz.part; do
    printf 'download\n' >"$pkgdir/$f"
done
# The per-rule probes (URL-backed; one per `*.<ext>` rule in the real
# .gitignore — the pairing's "every member of the ignore set is a target").
for name in "${probe_names[@]}"; do
    printf 'probe\n' >"$pkgdir/$name"
done
# A local asset and its signature: never a target, because neither is a URL.
for f in local.patch local.patch.sig; do
    printf 'asset\n' >"$pkgdir/$f"
done

# A VCS source that is shared by symlink, and a symlinked staging dir: the
# shared clone is deliberate sharing and must survive AND be reported; the
# staging link is a `prune staging` target whose link is unlinked while its
# target tree is never followed (see the DEVIATION above).
mkdir -p "$fixture/shared/shared" "$fixture/shared/src-target"
printf 'keep\n' >"$fixture/shared/src-target/marker"
ln -s "$fixture/shared/shared" "$pkgdir/shared"
ln -s "$fixture/shared/src-target" "$pkgdir/src"

# ─── 0. Ask first: the target list is the report, and nothing is deleted ────
run_engine "$fixture" -Mccc
ask_output=$FIXTURE_OUTPUT
((FIXTURE_RC == 3)) ||
    fail "bare -Mccc exited $FIXTURE_RC (want 3: confirmation-required): $(printf '%s' "$FIXTURE_OUTPUT" | tail -3)"
grep -q 'confirmation-required' <<<"$FIXTURE_OUTPUT" ||
    fail "bare -Mccc does not say confirmation is required: $(printf '%s' "$FIXTURE_OUTPUT" | tail -3)"
[[ -e "$pkgdir/art-3.0.zip" ]] ||
    fail "the ask-first path deleted art-3.0.zip before any confirmation"

# ─── 1. Every extension the ignore file denies is now a cleanup target ──────
for name in "${probe_names[@]}"; do
    grep -q "packages/demo/$name prune " <<<"$FIXTURE_OUTPUT" ||
        fail "the ask-first target list does not classify the probe for '$name' (a .gitignore rule without engine coverage): $(printf '%s' "$FIXTURE_OUTPUT" | tail -5)"
done

# The apply run deletes exactly the printed targets.
run_engine "$fixture" -Mccc --noconfirm
((FIXTURE_RC == 0)) ||
    fail "applying -Mccc exited $FIXTURE_RC: $(printf '%s' "$FIXTURE_OUTPUT" | tail -3)"
for name in "${probe_names[@]}"; do
    [[ ! -e "$pkgdir/$name" ]] || fail "a probe for a denied extension survived -Mccc: $name"
done
for f in thing-1.0.tar.xz bundle-2.0.tgz art-3.0.zip tool-4.0.jar \
    font-5.0.ttf wheel-6.0-py3-none-any.whl plain-7.0.tar \
    thing-1.0.tar.xz.sig thing-1.0.tar.xz.asc thing-1.0.tar.xz.part; do
    [[ ! -e "$pkgdir/$f" ]] || fail "a downloaded archive survived -Mccc: $f"
done

# ─── 2. A local asset is not a download and must survive ───────────────────
for f in local.patch local.patch.sig; do
    [[ -e "$pkgdir/$f" ]] || fail "a local, non-URL source was deleted: $f"
done
[[ -e "$pkgdir/keepme.txt" ]] ||
    fail "a URL-backed name no .gitignore rule denies was deleted: keepme.txt"

# ─── 3. Symlinks are preserved and reported, not followed ──────────────────
[[ -L "$pkgdir/shared" ]] || fail "the symlinked VCS source was deleted"
grep -q 'shared keep symlink' <<<"$FIXTURE_OUTPUT" ||
    fail "the kept VCS symlink is not reported as kept: $(printf '%s' "$FIXTURE_OUTPUT" | tail -5)"
[[ -L "$pkgdir/src" ]] &&
    fail "unexpected: the symlinked staging dir survived (the flip's DEVIATION expects the link pruned)"
[[ -e "$fixture/shared/src-target/marker" ]] ||
    fail "the pruned staging symlink was FOLLOWED — its target tree was deleted"

# ─── 4. The report names what it deleted, so a maintainer can audit it ─────
grep -q 'art-3.0.zip' <<<"$FIXTURE_OUTPUT" ||
    fail "-Mccc did not report the .zip it deleted: $(printf '%s' "$FIXTURE_OUTPUT" | tail -8)"
grep -q 'art-3.0.zip pruned ' <<<"$FIXTURE_OUTPUT" ||
    fail "the deletion of art-3.0.zip is not rendered as applied: $(printf '%s' "$FIXTURE_OUTPUT" | tail -8)"

# ─── 5. …and it survives a pipe, which is the interface scripts read ───────
# run_engine captures combined output through a pipe; the target rows must be
# in the piped capture, never only on a terminal rendering. The fish-era
# banner strings (`NUCLEAR`, `symlink(s) preserved`) retire (§L.3): the rows
# above are the report.
grep -q 'prune source-download' <<<"$ask_output" ||
    fail "the target classes are invisible in piped output"
grep -q 'keep symlink' <<<"$ask_output" ||
    fail "the kept-symlink row is invisible in piped output"

# ─── 6. The cleanup list and the ignore list are one list ──────────────────
# The invariant, seen from the engine: every `*.<ext>` rule the root
# .gitignore carries has a URL-backed probe the run prunes (assertion 1, each
# probe named in the target list and gone after the apply run), and no staged
# entry outside that set is touched (assertion 2). The fish-side half of the
# old pairing — the `_DOWNLOAD_ARCHIVE_EXTS` source list — retires (§6 R-1):
# the engine has no second list, so the pairing can no longer drift one way.

printf 'cleanup-extensions fixture: PASS\n'
