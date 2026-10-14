#!/usr/bin/env fish
# build-all.fish — RETIRED. The engine of record is the native `gsa` (Rust
# workspace at the repo root) since the Phase 5 cutover (2026-10-14). This
# shim exists so muscle memory fails loudly and helpfully: it prints the
# old-spelling → gsa-spelling migration table (docs/gsa-contract.md §B.9) and
# exits non-zero. It runs NOTHING.
#
# The fish engine itself is preserved verbatim as the FROZEN ORACLE under
# tests/assets/ (tests/assets/build-all.fish + tests/assets/lib/) — fixture
# sections that still compare against it run a copy of it beside their
# scratch workspace; it is not an engine any more.
#
# DEPRECATION WINDOW: this shim is kept for one release cycle after
# 2026-10-14 and then deleted. How to check the window has expired: if the
# frozen oracle (tests/assets/) has been diff-clean for a full release and no
# fixture section references the shim, remove this file in the same change
# that removes the oracle (docs/gsa-fixture-migration.md "Phase 5").

function _gsa_shim
    echo "build-all.fish: the fish builder is retired — the engine of record is 'gsa'."
    echo
    echo "Migration table (old spelling -> gsa spelling; docs/gsa-contract.md §B.9):"
    echo
    printf '  %-34s %s\n' "build-all.fish <old>" "<gsa>"
    printf '  %-34s %s\n' "----------------------------------" "----------------------------------"
    printf '  %-34s %s\n' "-g GRP / --group GRP" "gsa -S @GRP (groups and sets share @)"
    printf '  %-34s %s\n' "-l / --list" "gsa -Sl (also -Bl)"
    printf '  %-34s %s\n' "-n / --dry-run" "gsa --dry-run"
    printf '  %-34s %s\n' "-i / --install" "implicit in gsa -S (the family installs)"
    printf '  %-34s %s\n' "-fi / --forceinstall" "gsa -Sf / gsa -Uf"
    printf '  %-34s %s\n' "-ia / --installall [--overwrite …]" "gsa -Ua -- --overwrite …"
    printf '  %-34s %s\n' "--no-deps" "gsa --leaf"
    printf '  %-34s %s\n' "-c / --clean" "gsa -Mc, or the cluster letter c on -S/-B"
    printf '  %-34s %s\n' "-cc / --cleanup" "gsa -Mcc"
    printf '  %-34s %s\n' "-ccc / --nuclear" "gsa -Mccc (still prints targets, asks first)"
    printf '  %-34s %s\n' "-s / --skip" "gsa --skip (short -s dropped: s is search)"
    printf '  %-34s %s\n' "--skip-built" "gsa --skip-built"
    printf '  %-34s %s\n' "--vcs-skip-tolerance N" "gsa --vcs-skip-tolerance N"
    printf '  %-34s %s\n' "--no-sync" "gsa --no-sync"
    printf '  %-34s %s\n' "--audit" "gsa -Ma"
    printf '  %-34s %s\n' "--audit-lint FAMILY" "gsa --qa-check NAME (hidden seam)"
    printf '  %-34s %s\n' "--topology" "gsa -Qt"
    printf '  %-34s %s\n' "-ln / --link-sources" "gsa -Mm"
    printf '  %-34s %s\n' "--no-register-ignorepkg" "gsa --no-register-ignorepkg"
    printf '  %-34s %s\n' "--register-ignorepkg" "gsa -Mi --backfill"
    printf '  %-34s %s\n' "--lanes N / --jobs N / --intensity L" "same on gsa"
    printf '  %-34s %s\n' "--allow-broken-rustc" "gsa --allow-broken-rustc"
    printf '  %-34s %s\n' "-h / --help" "gsa --help"
    printf '  %-34s %s\n' "REF / PATH / pkgname / 22..38" "same targets and ranges on gsa"
    echo
    echo "Not carried (clean-slate re-contract, §B.9): -g as a flag (use @name),"
    echo "-i as a flag (the -S family IS the install decision), -s as a short flag,"
    echo "byte-identical output strings, and the format: 1 run record (now format: 2)."
    echo
    echo "Install and run the native engine instead, e.g.:"
    echo "    gsa -Sl                    # list the selection"
    echo "    gsa -B --leaf <recipe>     # build one recipe"
    echo "    gsa -S @git                # build + install the git group"
    echo "    gsa --help                 # the authoritative flag roster"
    echo
    echo "This shim prints this table and exits non-zero; it never builds anything."
    echo "It is kept for one release cycle after 2026-10-14 (deprecation window above)."
end

_gsa_shim
exit 2
