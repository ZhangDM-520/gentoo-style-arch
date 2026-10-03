# lib/pgo.sh — the one PGO payload-verification gate.
#
# Sourced by each PGO recipe's PKGBUILD:
#
#     source "$startdir/../../../lib/pgo.sh"
#
# and called as the LAST statement of every package function, against that
# function's own staged payload (a split recipe gates each `package_*`
# function's `$pkgdir`):
#
#     verify_no_profile_instrumentation "$pkgdir" [extra-literal...]
#
# One implementation on purpose. The seven per-recipe copies had already
# drifted (mold-git carried stricter predicates than the rest) and mandated
# copy-paste was itself the recurrence engine of the 2026-09-20
# instrumented-archive incident. A new PGO family extends THIS module and
# earns a fixture (tests/pgo-lib.sh pins the behaviour here); recipes only
# ever call it. A missing file fails loudly at PKGBUILD parse time — desired:
# a clean checkout must never build a PGO recipe without the gate.
#
# Fatal gate, deliberately: any hit prints the offending binary plus the
# predicate that matched, then calls `exit 1`, which kills makepkg's function
# subshell and fails the build. The `|| return 1` convention this replaces was
# unenforceable: bash returns the status of a function's LAST command, so a
# bare mid-body call whose failure a later command overwrote was silently
# discarded — the mechanism behind "guards" that never guarded anything.
# `exit` cannot be discarded.
#
# Call it at the END of the package function: nothing may be added to the
# payload after the gate runs, and the symbol predicate is only meaningful
# before makepkg strips.
#
# Two predicates per candidate file, because they cover different artifacts:
#   * `readelf -sW` — `__gcov_*` / `__llvm_profile*` instrumentation symbols.
#     Sound only pre-strip.
#   * `strings -a` — absolute `.gcda`/`.profraw` destinations baked into
#     .rodata. The only evidence that survives stripping, so an installed
#     binary stays auditable (measured 2026-09-19: readelf reported clean on
#     a stripped Xwayland while strings found all 348 baked paths).
# Extra literal arguments (e.g. mold-git's `pgo-data` profile work directory)
# are matched verbatim with `strings`, for destinations that carry no suffix.

_pgo_fail() {
  if declare -F error >/dev/null 2>&1; then
    error "$*"
  else
    printf 'ERROR: %s\n' "$*" >&2
  fi
  exit 1
}

# ---------------------------------------------------------------------------
# Training bound — the second shared PGO seam (added 2026-10-03 after the
# gtk4-git training run OOM-killed a whole build unit: 583 spawn/crash cycles
# in 26 s, one systemd-coredump spawn per crash, zero profile written).
#
#     pgo_train_meson [--display-suite] <builddir> <budget-seconds> [meson test args...]
#
# Recipes call this instead of a hand-rolled `timeout … meson test … || true`
# line (eight near-identical copies existed; copy-paste is the recurrence
# engine this module exists to kill). The call is failure-guarded by
# construction: a training run may never fail the build — a thin profile is
# the recipe's floor guard problem, not a build error.
#
# The bounds, and what each one measured to be load-bearing:
#   * wall budget via `timeout -k 5 <budget>` — bounds the run's duration;
#   * `--num-processes 4` — caps CONCURRENT test processes (meson's default
#     is nproc-driven and instantiated ~24 GTK processes at once in the
#     incident). Measured per abort cycle: ~43 MB RSS, 269 major faults,
#     ~35k file-input blocks (~17 MB read) — the marginal cost is churn rate
#     and fault/IO pressure, not per-cycle footprint;
#   * `ulimit -c 0` in the subtree — each SIGABRT otherwise enters the
#     kernel core pipeline and spawns systemd-coredump (measured: exactly
#     one handler per crash, 24/24 at repro scale). A crash-churning suite
#     turns that into hundreds of handler spawns per minute;
#   * `--no-rebuild` — training never triggers surprise compiles inside the
#     budget (house precedent: systemd, util-linux, wayland, libinput).
#
# `--display-suite`: when the host exposes no display but ships xvfb-run, the
# suite runs under `xvfb-run -a -s '-nolisten local'` (the display-suite
# convention of packages/stable/libnotify and zen-browser-pgo) so
# display-dependent tests actually execute and write profiles instead of
# aborting at gtk_init with zero output. Without either, the run stays
# bounded; the recipe's floor guard decides the profile's fate.
pgo_display_available() {
  test -n "${DISPLAY:-}" || test -n "${WAYLAND_DISPLAY:-}" ||
    command -v xvfb-run >/dev/null 2>&1
}

pgo_train_meson() {
  local _display_suite=0
  if test "${1:-}" = --display-suite; then
    _display_suite=1
    shift
  fi
  local _dir="$1" _budget="$2"
  shift 2
  (
    ulimit -c 0 2>/dev/null || true
    local _run=(timeout -k 5 "$_budget" meson test -C "$_dir"
      --num-processes 4 --no-rebuild --print-errorlogs "$@")
    if test "$_display_suite" = 1 && test -z "${DISPLAY:-}" &&
      test -z "${WAYLAND_DISPLAY:-}" && command -v xvfb-run >/dev/null 2>&1; then
      _run=(xvfb-run -a -s '-nolisten local' "${_run[@]}")
    fi
    "${_run[@]}"
  ) || true
  return 0
}

verify_no_profile_instrumentation() {
  local _root="$1"
  shift
  local _binary _extra
  local _who="${pkgbase:-${pkgname[0]:-package}}"
  while IFS= read -r -d '' _binary; do
    if readelf -sW "$_binary" 2>/dev/null | grep -Eq '__gcov_|__llvm_profile'; then
      _pgo_fail "$_who: final payload still contains profile instrumentation ($_binary; readelf symbol predicate)"
    fi
    # The char class excludes `/` and `*` for a reason: ctest legitimately
    # ships the glob literal `/*.gcda` in its own GCOV support, and a glob is
    # not a baked destination. Without the exclusion a correctly rebuilt
    # cmake-git fails its own guard.
    if strings -a "$_binary" 2>/dev/null | grep -qE '^/[^[:space:]/*][^[:space:]]*\.(gcda|profraw)'; then
      _pgo_fail "$_who: final payload still carries baked profile destinations ($_binary; strings path predicate)"
    fi
    for _extra in "$@"; do
      if strings -a "$_binary" 2>/dev/null | grep -qF "$_extra"; then
        _pgo_fail "$_who: final payload still carries the PGO work directory literal '$_extra' ($_binary; strings literal predicate)"
      fi
    done
  done < <(find "$_root" -type f \( -name '*.so' -o -name '*.so.*' -o -perm -u+x \) -print0)
}
