#!/usr/bin/env bash
set -euo pipefail

# Pin the fzf Go-PGO contract. Static inspection only — this never runs a
# build.
#
# Go is the first PGO family with no compiler instrumentation in the
# payload: `go build -pgo=` consumes a runtime/pprof CPU profile as a build
# INPUT, so the shared gate's predicates (instrumentation symbols, baked
# .gcda/.profraw destinations) trivially pass. The pins below cover what the
# gate cannot see:
#
#   1. Training runs at all: upstream `make bench` with -cpuprofile over the
#      matcher packages, plus `fzf --filter` runs from a -tags=pprof trainer
#      (the only build with --profile-cpu support).
#   2. The profile is wired into the release build (-pgo=<file> here;
#      default.pgo placement is the equally valid Go-doc mechanism).
#   3. Underproduction falls back to -pgo=off with a logged reason behind a
#      pgo_min_samples floor — the build must never fail because training
#      underproduced, so every training command is failure-guarded with
#      `|| true` (makepkg runs build() under errexit with an ERR trap).
#   4. The shared gate stays the LAST statement of package().
#   5. Release flags stay intact (GOFLAGS, -linkmode external, the -a drop)
#      and check() still runs `go test ./...`.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
recipe="packages/stable/fzf"
pkgbuild="$root/$recipe/PKGBUILD"

fail() {
    printf 'fzf-pgo: %s\n' "$1" >&2
    exit 1
}

test -f "$pkgbuild" || fail "missing $recipe/PKGBUILD"

bash -n "$pkgbuild" || fail "PKGBUILD does not parse under bash -n"

# --- 1. training invocation -------------------------------------------
grep -Fq -- '-cpuprofile=' "$pkgbuild" ||
    fail "no CPU-profile training run (-cpuprofile=)"
grep -Fq -- '-bench=.' "$pkgbuild" ||
    fail "no upstream benchmark training run (make bench equivalent)"
grep -Fq -- '--profile-cpu' "$pkgbuild" ||
    fail "no fzf --filter training (--profile-cpu)"
grep -Fq -- '-tags=pprof' "$pkgbuild" ||
    fail "trainer is not built with -tags=pprof (needed for --profile-cpu)"

# Training must be unable to abort the build: every training command is
# guarded with `|| true`.
while IFS= read -r line; do
    [[ $line == *'|| true'* ]] ||
        fail "training command is not failure-guarded with || true: $line"
done < <(awk '!/^[[:space:]]*#/ && /(-cpuprofile=|fzf-train|-tags=pprof|go tool pprof -proto)/' "$pkgbuild")

# --- 2. profile wiring -------------------------------------------------
# This flavor wires the profile with -pgo=<file>; default.pgo placement in
# the main-package directory is the equally valid Go-doc mechanism.
grep -Fq -- '-pgo=$profile"' "$pkgbuild" ||
    grep -Fq 'default.pgo' "$pkgbuild" ||
    fail "no profile wiring (-pgo=<file> or default.pgo) into the release build"

# --- 3. floor + fallback ----------------------------------------------
grep -Eq 'local pgo_min_samples=[0-9]+' "$pkgbuild" ||
    fail "no per-recipe pgo_min_samples floor"
grep -Fq 'Total samples' "$pkgbuild" ||
    fail "floor is not derived from the 'go tool pprof -top' sample total"
grep -Fq -- '-pgo=off' "$pkgbuild" ||
    fail "no -pgo=off fallback"
grep -Fq 'PGO profile too thin' "$pkgbuild" ||
    fail "fallback does not log why the profile was rejected"

# --- 4. gate is the last statement of package() ------------------------
last=$(awk '/^package\(\)[[:space:]]*\{/ { in_pkg = 1; next }
            in_pkg && /^[[:space:]]*}/ { exit }
            in_pkg && $0 !~ /^[[:space:]]*(#|$)/ { last = $0 }
            END { print last }' "$pkgbuild")
gate_re='^[[:space:]]*verify_no_profile_instrumentation[[:space:]]+"\$pkgdir"[[:space:]]*$'
[[ $last =~ $gate_re ]] ||
    fail "gate is not the last statement of package(): '${last:-<empty>}'"

# --- 5. release flags intact ------------------------------------------
grep -Fq 'export GOFLAGS="-buildmode=pie -trimpath -mod=readonly -modcacherw"' "$pkgbuild" ||
    fail "base GOFLAGS (-buildmode=pie -trimpath -mod=readonly -modcacherw) changed"
grep -Fq 's/-w /-w -linkmode external /' "$pkgbuild" ||
    fail "-linkmode external sed is missing"
grep -Fq 's/-a -ldflags/-ldflags/' "$pkgbuild" ||
    fail "go build -a removal sed is missing"
grep -Fq 'go test ./...' "$pkgbuild" ||
    fail "check() no longer runs go test ./..."

printf 'fzf-pgo fixture: PASS\n'
