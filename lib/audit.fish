# lib/audit.fish — Design C leaf module: the workspace audit lints (recipe
# contract + the two ABI audit lints) and the IgnorePkg mutation seam.
# Extracted verbatim from build-all.fish (2026-10-05, Design C minimal modular
# split): function names and behaviour are unchanged; the entry sources this
# file before load_project_config and the hidden seam blocks (--audit-lint,
# --register-ignorepkg), so every caller sees the same flat fish function
# namespace as before the split.
#
# Interface: the functions themselves. This module WRITES no global state —
# it reads the topology globals (_PACKAGE_MAP, _TAGS, ...) and the shared
# parses (srcinfo_rows / pkgbuild_scan_rows from lib/sources.fish), and
# register_ignorepkg mutates only its target pacman.conf (plus its dated
# backup). Out-param style globals: none.

# ─── Layer 1 + 5: the ABI audit lints (report-only everywhere) ──────────────
# audit_lint_abi_closure (layer 1) and audit_lint_abi_exposure (layer 5) join
# the recipe-contract lints: rendered in --audit's report, individually
# runnable through the hidden --audit-lint seam. Findings never change an exit
# status — the gating is fixtures + the install/batch layers above.

# Layer 1: the closure lint over WORKSPACE-BUILT OUTPUTS (the archives beside
# each recipe — the only place the shipped ELF surface is real). Two rules:
#   ship    every DT_SONAME an output ships needs a bare soname provide in
#           its recipe's committed .SRCINFO;
#   needed  every DT_NEEDED of an output resolves to (a) a workspace provide,
#           (b) an expected base-system soname, or (c) an exclusions entry.
# Findings name the provider/consumer pair. Without built outputs the lint
# reports `skipped` (nothing shipped can be probed on a clean checkout).
function audit_lint_abi_closure
    for tool in tar readelf
        if not command -q $tool
            echo "abi-closure: skipped — $tool is not available"
            return 0
        end
    end
    set -l tmp_root "$TMPDIR"
    if test -z "$tmp_root"
        set tmp_root /tmp
    end
    set -l work (mktemp -d "$tmp_root/gsa-abi-closure.XXXXXX" 2>/dev/null)
    if test -z "$work"
        echo "abi-closure: skipped — cannot create a temp dir to probe built outputs"
        return 0
    end
    # File-backed accumulation (F6): declared rows come from the ONE shared
    # .SRCINFO parse instead of a sed fork per recipe, and the big row lists
    # append to files — `set -a` on a 35k-row list copies it whole every time
    # — then materialise once. Order is preserved end to end (the provider/
    # mismatch assembly below reads declared in its declared order).
    set -l decl_file "$work/declared"
    set -l ship_file "$work/shipped"
    set -l need_file "$work/needed"
    for row in (srcinfo_rows P)
        set -l parts (string split -m 2 '|' -- "$row")
        printf '%s\n' "$parts[1]|$parts[3]" >> "$decl_file"
    end
    set -l declared # id|provide-entry
    test -f "$decl_file"; and set declared (cat "$decl_file")
    set -l outputs 0
    for entry in $_PACKAGE_MAP
        set -l fields (string split '|' -- "$entry")
        set -l id $fields[1]
        set -l recipe "$SCRIPT_DIR/$fields[2]"
        set -l n 0
        for archive in (list_split_pkgs "$recipe")
            set n (math $n + 1)
            set outputs (math $outputs + 1)
            set -l dest "$work/$id-$n"
            mkdir -p "$dest"
            if not tar -xf "$archive" -C "$dest" 2>/dev/null
                printf '%s\n' "$id|(unreadable)|(unreadable)" >> "$ship_file"
                continue
            end
            # ONE readelf per bounded path batch instead of one process per
            # member (35k processes at 653-record scale — the single largest
            # --audit cost). The batch caps argv below the OS limit: one
            # archive's file list alone (a bundled python venv) is 4MB of
            # paths. Batch output is split back into per-file chunks at its
            # "File: " headers and each chunk feeds the SAME SONAME/NEEDED
            # seds as before; a non-ELF member prints no header and is skipped
            # exactly like the old per-file count guard. A sentinel header
            # flushes the last real chunk.
            set -l files (find "$dest" -type f 2>/dev/null)
            set -l batch
            set -l nfiles (count $files)
            set -l f0 1
            while test $f0 -le $nfiles
                set -l f1 (math $f0 + 255)
                test $f1 -gt $nfiles; and set f1 $nfiles
                set -a batch (readelf -dW $files[$f0..$f1] 2>/dev/null)
                set f0 (math $f1 + 1)
            end
            set -a batch "File: "
            set -l chunk_rel ""
            set -l chunk
            for raw in $batch
                if string match -q 'File: *' -- "$raw"
                    if test -n "$chunk_rel"
                        set -l rel (string replace "$dest/" '' -- "$chunk_rel")
                        # Same extractions as the old per-file
                        # `printf | sed -n 's/^.*SONAME.*\[\(.*\)\]$/\1/p'`
                        # (and the NEEDED twin) — same patterns, same
                        # one-value-per-line result — but in-process: a pipe +
                        # sed fork per member cost more than the readelf scan
                        # itself at 33k members. The glob precheck is the sed
                        # pattern's ".*SONAME.*" half; empty captures drop out
                        # of the substitution exactly like sed's empty line.
                        for line in $chunk
                            if string match -q '*SONAME*' -- "$line"
                                set -l m (string match -r -g '^.*SONAME.*\[(.*)\]$' -- "$line")
                                test (count $m) -ge 1; and printf '%s\n' "$id|$rel|$m[1]" >> "$ship_file"
                            end
                            if string match -q '*NEEDED*' -- "$line"
                                set -l m (string match -r -g '^.*NEEDED.*\[(.*)\]$' -- "$line")
                                test (count $m) -ge 1; and printf '%s\n' "$id|$rel|$m[1]" >> "$need_file"
                            end
                        end
                    end
                    set chunk_rel (string replace -r '^File: ' '' -- "$raw")
                    set chunk
                else if test -n "$chunk_rel"
                    set -a chunk "$raw"
                end
            end
        end
    end
    set -l shipped # id|member|soname
    set -l needed # id|member|soname
    test -f "$ship_file"; and set shipped (cat "$ship_file")
    test -f "$need_file"; and set needed (cat "$need_file")
    set -l findings
    if test $outputs -eq 0
        command rm -rf -- "$work"
        echo "abi-closure: skipped — no workspace-built outputs (build the recipes to enable the closure probe)"
        return 0
    end
    # Provide-name index over $declared. Both rules below can only cover a
    # soname with an entry whose NAME equals the soname or its bare stem
    # (see abi_provide_covers), so the old scan over every declared row per
    # shipped/needed row — 843k covers calls at 653-record scale — becomes one
    # name test per row plus a covers call on candidates alone. Rows keep
    # their declared order, which is the order provider/mismatch assembly
    # below depends on.
    set -l decl_id
    set -l decl_value
    set -l decl_name
    for d in $declared
        set -l dp (string split -m 1 '|' -- "$d")
        set -l pp (string split -m 1 '=' -- "$dp[2]")
        set -a decl_id "$dp[1]"
        set -a decl_value "$dp[2]"
        set -a decl_name (string trim -- "$pp[1]")
    end
    set -l decl_idx (seq (count $decl_id))
    # Rule ship: a shipped DT_SONAME needs its bare soname provide.
    for row in $shipped
        set -l parts (string split '|' -- "$row")
        set -l id $parts[1]
        set -l member $parts[2]
        set -l soname $parts[3]
        abi_excluded "$id"; and continue
        if test "$soname" = "(unreadable)"
            set -a findings "abi-closure: $id: cannot extract $member — built outputs not probed"
            continue
        end
        set -l stem (_lint_soname_stem "$soname")
        test (count $stem) -ge 1; or continue
        set -l covered 0
        for j in $decl_idx
            test "$decl_id[$j]" = "$id"; or continue
            test "$decl_name[$j]" = "$soname"; or test "$decl_name[$j]" = "$stem"; or continue
            if abi_provide_covers "$decl_value[$j]" "$soname"
                set covered 1
                break
            end
        end
        test $covered -eq 1; and continue
        set -a findings "abi-closure: provider $id: ships $member with soname '$soname' but declares no bare soname provide '$stem' — declare provides=('$stem') and let makepkg auto-version it"
    end
    # Rule needed: every DT_NEEDED resolves to (a), (b) or (c).
    for row in $needed
        set -l parts (string split '|' -- "$row")
        set -l id $parts[1]
        set -l member $parts[2]
        set -l soname $parts[3]
        abi_excluded "$id"; and continue
        abi_base_lib_ok "$soname"; and continue
        abi_excluded "$soname"; and continue
        set -l stem (_lint_soname_stem "$soname")
        set -l providers
        set -l resolved 0
        set -l mismatch
        for j in $decl_idx
            test "$decl_name[$j]" = "$soname"; or test "$decl_name[$j]" = "$stem"; or continue
            abi_provide_covers "$decl_value[$j]" "$soname"; or continue
            contains -- "$decl_id[$j]" $providers; and continue
            set -a providers "$decl_id[$j]"
        end
        for pid in $providers
            set -l has_outputs 0
            set -l ships 0
            set -l shipped_names
            for s in $shipped
                set -l sp (string split '|' -- "$s")
                test "$sp[1]" = "$pid"; or continue
                set has_outputs 1
                if test "$sp[3]" = "$soname"
                    set ships 1
                end
                set -l sstem (_lint_soname_stem "$sp[3]")
                if test (count $sstem) -ge 1
                    set -l wstem (_lint_soname_stem "$soname")
                    if test (count $wstem) -ge 1; and test "$sstem[1]" = "$wstem[1]"
                        set -a shipped_names "$sp[3]"
                    end
                end
            end
            if test $ships -eq 1; or test $has_outputs -eq 0
                set resolved 1
                break
            end
            set -a mismatch "$pid: "(string join ', ' $shipped_names)
        end
        test $resolved -eq 1; and continue
        if test (count $providers) -gt 0
            set -a findings "abi-closure: consumer $id ($member) needs '$soname' but provider "(string join ' / ' $mismatch)" — the provider/consumer pair must move in one batch"
        else
            set -a findings "abi-closure: consumer $id ($member) needs '$soname' — no workspace provider declares it, it is not an expected base-system lib, and no config/abi-exclusions.conf entry covers it"
        end
    end
    command rm -rf -- "$work"
    if test (count $findings) -gt 0
        printf '%s\n' $findings | sort -u
    end
    return 0
end

# Layer 5: the exposure audit. For every workspace lib whose soname provides
# (committed .SRCINFO bare stems) differ from the installed stock equivalent
# (abi_installed_provides of abi_stock_name — the installed database answer
# for the stock name), report the provider → exposed-consumer mapping: one
# row per drifted provide per installed consumer whose Depends On reaches the
# drift (the drifted soname name or the stock name), `-> none` when nothing
# installed depends on it. Report-only: the mapping tells the maintainer who
# is exposed when the swap lands; the batch/install layers above do the
# gating.
function audit_lint_abi_exposure
    if not command -q pacman
        echo "abi-exposure: skipped — pacman is not available"
        return 0
    end
    set -l tmp_root "$TMPDIR"
    if test -z "$tmp_root"
        set tmp_root /tmp
    end
    set -l work (mktemp -d "$tmp_root/gsa-abi-exposure.XXXXXX" 2>/dev/null)
    if test -z "$work"
        echo "abi-exposure: skipped — no scratch directory can be created under $tmp_root"
        return 0
    end
    # F4: the installed database enters ONCE. A single field-tracked awk pass
    # over the one full `pacman -Qi` dump writes `C|consumer|depname` rows
    # (Depends On tokens, version suffix stripped by abi_provide_name's rule)
    # instead of marshalling the 10k+ pairs through a fish list for every
    # drift row to string-match against. The field walk replicates the old
    # per-line one exactly: a header line takes its value's tokens with the
    # literal `None` dropped, a wrapped continuation keeps them (the old loop
    # skipped None only in the header branch), and a Depends On value only
    # ever attaches to the Name field above it.
    LANG=C pacman -Qi 2>/dev/null | awk '
        function emit_dep(value, x) {
            x = value
            sub(/[=<>].*$/, "", x)
            gsub(/^[ \t\r\n\f\v]+|[ \t\r\n\f\v]+$/, "", x)
            print "C|" cur_name "|" x
        }
        {
            line = $0
            if (line ~ /^[ \t]*[A-Za-z][A-Za-z ]*[ \t]*:[ \t]*/) {
                f = line
                sub(/:.*/, "", f)
                gsub(/^[ \t]+|[ \t]+$/, "", f)
                v = line
                sub(/^[ \t]*[A-Za-z][A-Za-z ]*[ \t]*:[ \t]*/, "", v)
                if (f == "Name") {
                    gsub(/^[ \t]+|[ \t]+$/, "", v)
                    cur_name = v
                } else if (f == "Depends On") {
                    gsub(/\t/, " ", v)
                    n = split(v, t, " ")
                    for (i = 1; i <= n; i++) {
                        if (t[i] == "" || t[i] == "None") continue
                        if (cur_name == "") continue
                        emit_dep(t[i])
                    }
                }
                field = f
                next
            }
            if (field == "Depends On") {
                gsub(/\t/, " ", line)
                gsub(/^[ \t]+|[ \t]+$/, "", line)
                n = split(line, t, " ")
                for (i = 1; i <= n; i++) {
                    if (t[i] == "" || cur_name == "") continue
                    emit_dep(t[i])
                }
            }
        }' > "$work/deps"
    # F6: the recipe side walks the shared .SRCINFO parse (srcinfo_rows) —
    # names from the B/N rows, provide values from the P rows, the one name
    # surface _pkgname_index shares. The exact predicates (abi_soname_stems,
    # abi_provide_name, abi_stock_name) stay fish-side and land in the row
    # files as DATA; everything after this walk is one awk join, so a finding
    # never round-trips through an interpreted list.
    set -l rows "$work/rows"
    set -l all_stocks
    set -l row_id ''
    set -l skip 0
    set -l names
    set -l house_values
    for row in (srcinfo_rows) '__flush__|'
        set -l parts (string split -m 3 '|' -- "$row")
        set -l id $parts[2]
        if test "$id" != "$row_id"
            if test -n "$row_id"
                if test $skip -eq 0
                    set -l house
                    for value in $house_values
                        set -l st (abi_soname_stems "$value")
                        set -l stem ''
                        test (count $st) -ge 1; and set stem $st[1]
                        test -n "$stem"; and set -a house $stem
                        set -l pn (abi_provide_name "$value")
                        printf 'HV|%s|%s|%s|%s\n' "$row_id" "$stem" "$pn" "$value" >> "$rows"
                    end
                    # The candidate gate is the old `house` guard: only a
                    # recipe carrying soname-shaped provides is compared, and
                    # only its stock names are queried.
                    if test (count $house) -gt 0
                        test (count $names) -gt 0; or set names $row_id
                        for name in $names
                            set -l stock (abi_stock_name "$name")
                            printf 'N|%s|%s\n' "$row_id" "$name" >> "$rows"
                            printf 'R|%s|%s\n' "$row_id" "$stock" >> "$rows"
                            set -a all_stocks $stock
                        end
                    end
                end
            end
            test "$id" = ''; and break
            set row_id "$id"
            set skip 0
            abi_excluded "$id"; and set skip 1
            set names
            set house_values
        end
        test $skip -eq 1; and continue
        switch $parts[1]
            case P
                set -a house_values "$parts[4]"
            case B
                contains -- "$parts[3]" $names; or set -a names "$parts[3]"
            case N
                contains -- "$parts[3]" $names; or set -a names "$parts[3]"
        end
    end
    # F4's second half: the stock lookup is ONE abi_installed_provides_batch
    # over every candidate stock (256-name chunks of `pacman -Qi`, per-name
    # fallback inside) instead of one fork per name (~650 forks).
    set -l batch_rows
    if test (count $all_stocks) -gt 0
        set batch_rows (abi_installed_provides_batch $all_stocks)
    end
    set -l compared 0
    test (count $batch_rows) -gt 0; and set compared 1
    for row in $batch_rows
        set -l bp (string split -m 1 '|' -- "$row")
        set -l st (abi_soname_stems "$bp[2]")
        set -l stem ''
        test (count $st) -ge 1; and set stem $st[1]
        set -l pn (abi_provide_name "$bp[2]")
        printf 'V|%s|%s|%s|%s\n' "$bp[1]" "$stem" "$pn" "$bp[2]" >> "$rows"
    end
    for consumer in (awk -F'|' '!seen[$2]++ {print $2}' "$work/deps")
        abi_excluded "$consumer"; and printf 'X|%s\n' "$consumer" >> "$rows"
    end
    # The join computes the drift rows (stock-only / house-only, exact stem
    # sets supplied fish-side) and the provider → exposed-consumer mapping in
    # one pass. Findings accumulate in awk and are sort -u'ed on print, so
    # neither drift nor finding count can quadratic a fish list.
    awk '
        function add_drift(idx, stock, value, kind, dname, d) {
            d = ++nd
            did[d] = idx
            dstk[d] = stock
            dval[d] = value
            dkind[d] = kind
            if (!(dname in kseen)) { kseen[dname] = 1; keys[++nk] = dname }
            kdr[dname, ++kn[dname]] = d
            if (!(stock in kseen)) { kseen[stock] = 1; keys[++nk] = stock }
            kdr[stock, ++kn[stock]] = d
        }
        function emit_row(d, c) {
            if (dkind[d] == "stock-only")
                print "exposure: " did[d] " -> " c ": stock " dstk[d] " carries \047" dval[d] "\047 but " did[d] " drops it"
            else
                print "exposure: " did[d] " -> " c ": " did[d] " carries \047" dval[d] "\047 that stock " dstk[d] " does not"
        }
        {
            n = split($0, a, "|")
            t = a[1]
            if (t == "C") {
                key = a[3]
                c = a[2]
                if (!cseen[key SUBSEP c]++) clist[key, ++cn[key]] = c
                next
            }
            if (t == "X") { x[a[2]] = 1; next }
            if (t == "V") {
                s = a[2]
                vn[s]++
                vstem[s, vn[s]] = a[3]
                vname[s, vn[s]] = a[4]
                v = a[5]
                for (z = 6; z <= n; z++) v = v "|" a[z]
                vval[s, vn[s]] = v
                next
            }
            if (t == "R") {
                i = a[2]
                if (!(i in rin)) { rin[i] = 1; ridx[++nr] = i }
                rstock[i, ++rn[i]] = a[3]
                next
            }
            if (t == "N") { own[a[2], a[3]] = 1; next }
            if (t == "HV") {
                i = a[2]
                hn[i]++
                hstem[i, hn[i]] = a[3]
                hname[i, hn[i]] = a[4]
                v = a[5]
                for (z = 6; z <= n; z++) v = v "|" a[z]
                hval[i, hn[i]] = v
                if (a[3] != "") hset[i, a[3]] = 1
                next
            }
        }
        END {
            for (i = 1; i <= nr; i++) {
                idx = ridx[i]
                ni = 0
                for (j = 1; j <= rn[idx]; j++) {
                    s = rstock[idx, j]
                    for (k = 1; k <= vn[s]; k++) {
                        ni++
                        istk[ni] = s
                        ival[ni] = vval[s, k]
                        istem[ni] = vstem[s, k]
                        iname[ni] = vname[s, k]
                    }
                }
                if (ni == 0) continue
                for (j = 1; j <= ni; j++) {
                    st = istem[j]
                    if (st == "") continue
                    if ((idx, st) in hset) continue
                    add_drift(idx, istk[j], ival[j], "stock-only", iname[j])
                }
                delete iall
                for (j = 1; j <= ni; j++) if (istem[j] != "") iall[istem[j]] = 1
                for (j = 1; j <= hn[idx]; j++) {
                    st = hstem[idx, j]
                    if (st == "") continue
                    if (st in iall) continue
                    add_drift(idx, istk[1], hval[idx, j], "house-only", hname[idx, j])
                }
            }
            for (i = 1; i <= nk; i++) {
                key = keys[i]
                for (j = 1; j <= kn[key]; j++) {
                    d = kdr[key, j]
                    idx = did[d]
                    for (k = 1; k <= cn[key]; k++) {
                        c = clist[key, k]
                        if (c in x) continue
                        if ((idx, c) in own) continue
                        if ((d, c) in hit) continue
                        hit[d, c] = 1
                        cnt[d]++
                        emit_row(d, c)
                    }
                }
            }
            for (d = 1; d <= nd; d++) if (!(d in cnt)) emit_row(d, "none")
        }' "$work/deps" "$work/rows" > "$work/findings"
    if test $compared -eq 0
        echo "abi-exposure: skipped — no workspace lib has an installed stock equivalent to compare against"
        command rm -rf -- "$work"
        return 0
    end
    if test -s "$work/findings"
        sort -u "$work/findings"
    end
    command rm -rf -- "$work"
    return 0
end

# ─── Workspace audit lints (recipe contract) ─────────────────────────────────
# One implementation per rule, two consumers: audit_workspace renders these
# into --audit's report and the hidden --audit-lint seam (bottom of this file)
# runs one of them against the loaded workspace. tests/recipe-contract.sh is
# the gating walker for provides/purged, tests/swap-completeness.sh
# for swap. All four lints are REPORT-ONLY everywhere: a finding never
# changes an exit status. Inputs are the committed .SRCINFO files — the
# same metadata install/depends decisions read — PKGBUILD is never evaluated.
#
# Rules (docs/MEMORY.md provides discipline + purged tools):
#   provides   the Q8 mapping scope is SONAME + NAME, and the two sides get
#              opposite forms. SONAME: BARE stems only (`libfoo.so`, never
#              `libfoo.so=2-64`: makepkg auto-versions a bare stem from the
#              built ELF, a hand-pinned one only rots). NAME: a versioned
#              name-provide wherever the recipe MAPS a stock name — it swaps
#              it (also declares it in conflicts, the Class A shape
#              `provides=(<stock>=$pkgver)` + `conflicts=(<stock>)`), is the
#              stock counterpart of one of its outputs (the swap rule's
#              VCS-suffix derivation), or compat-maps an output name — the
#              output name can belong to any workspace recipe, because a
#              compat map can target a sibling recipe's output
#              (wireplumber→pipewire-session-manager), not just its own —
#              plus a VERSIONED name-provide wherever some workspace consumer
#              constrains that name. The reason is the same in both NAME
#              cases: an unversioned provide cannot satisfy `>=N`, so pacman
#              silently falls back to the repo package (the meson incident
#              class). A provide maps nothing when it carries no routing
#              weight: a capability virtual (`libgl`, `ladspa-host`) and a
#              package providing its own name both stay unversioned.
#   purged     host-purged tools must not re-enter through makedepends/
#              checkdepends (makepkg reinstalls them silently).
#   swap       the stock→house swap must be COMPLETE: a pkgname with a VCS
#              suffix (-git/-svn/-hg/-snapshot) must provide AND conflict its
#              stock counterpart (strip the suffix), so pacman's `--ask 4`
#              conflict removal actually replaces the stock package and
#              dependents of the stock name resolve to this build. Empty
#              provides/conflicts entries are flagged outright — a split
#              output's unset array slot ships as `provides = `, metadata
#              that names nothing. Names only, any version satisfies.

# Bare soname stem for a provide NAME ('libfoo.so' or 'libfoo.so.1.2' →
# 'libfoo.so'); prints nothing when the name is not soname-shaped.
function _lint_soname_stem -a name
    if string match -qr '^(.+)\.so$' -- "$name"
        printf '%s\n' "$name"
        return 0
    end
    set -l m (string match -r -g '^(.+)\.so\..+$' -- "$name")
    if test (count $m) -ge 1
        printf '%s.so\n' $m[1]
    end
    return 0
end

function audit_lint_provides
    set -l constraints # name|op|ver|consumer — every versioned dep in the set
    set -l entries # id|carrier|provide-value — every provide in the set
    set -l mapping # id|name — every stock name a recipe swaps or derives
    set -l output_names # every workspace output name, the compat-map registry
    set -l recipe_outputs # id|name — needed to tell a self-provide from a map
    # ONE shared .SRCINFO parse (srcinfo_rows) replaces the per-recipe tagged
    # sed pass: one workspace read instead of one fork per recipe per lint.
    # Rows arrive grouped per recipe in $_PACKAGE_MAP order; the trailing
    # sentinel row flushes the last recipe through the same branch a recipe
    # change takes. Every findings list below ends `sort -u`, so walk order is
    # output-invisible.
    set -l row_id ''
    set -l outputs # the pkgname values, the real outputs of this recipe
    set -l base_names # pkgbase, used only when no pkgname line exists
    set -l conflict_names
    for row in (srcinfo_rows) '__flush__|'
        set -l parts (string split -m 3 '|' -- "$row")
        set -l id $parts[2]
        if test "$id" != "$row_id"
            if test -n "$row_id"
                # Mapping names, per recipe: the conflicted stock names (the swap) and
                # each output's stock counterpart (strip the VCS suffix — the swap
                # rule's derivation; a suffixless output "derives" only itself, which
                # maps nothing). Compat-maps are not listed here: whether a provide of
                # an output name is a map depends on which output carries it, so the
                # findings loop below decides them against the carrier.
                test (count $outputs) -gt 0; or set outputs $base_names
                for name in $conflict_names
                    set -a mapping "$row_id|$name"
                end
                for name in $outputs
                    set -a output_names $name
                    set -a recipe_outputs "$row_id|$name"
                    set -l stock (string replace -r -- '-(git|svn|hg|snapshot)$' '' "$name")
                    test "$stock" = "$name"; or set -a mapping "$row_id|$stock"
                end
            end
            test "$id" = ''; and break
            set row_id "$id"
            set outputs
            set base_names
            set conflict_names
            set carrier ''
        end
        switch $parts[1]
            case P
                test -n "$parts[4]"; or continue
                set -a entries "$id|$parts[3]|$parts[4]"
            case C
                test -n "$parts[4]"; or continue
                set -a conflict_names (string replace -r '[=<>].*$' '' -- "$parts[4]")
            case N
                set -a outputs "$parts[3]"
            case B
                set -a base_names "$parts[3]"
            case D
                test -n "$parts[4]"; or continue
                set -l value "$parts[4]"
                # optdepends carry a `: description` suffix; names never do.
                set -l v (string split -m1 ':' -- "$value")[1]
                set -l m (string match -r -g '^(.+?)(>=|<=|=|>|<)(.+)$' -- (string trim -- $v))
                test (count $m) -ge 3; or continue
                set -a constraints "$m[1]|$m[2]|$m[3]|$id"
        end
    end

    set -l findings
    for entry in $entries
        set -l parts (string split -m 2 '|' -- $entry)
        set -l id $parts[1]
        set -l carrier $parts[2]
        set -l value $parts[3]
        set -l pp (string split -m 1 '=' -- $value)
        set -l name $pp[1]
        set -l ver ''
        test (count $pp) -ge 2; and set ver $pp[2]
        test -n "$name"; or continue
        set -l stem (_lint_soname_stem "$name")
        if set -q stem[1]
            if string match -q '*.so.*' -- "$name"
                set -a findings "provides: $id: soname provide '$value' names a versioned soname — declare the bare stem '$stem'"
            else if test -n "$ver"
                set -a findings "provides: $id: soname provide '$value' is hand-versioned — declare the bare stem '$name' and let makepkg auto-version it from the built ELF"
            end
            continue
        end
        # Q8 NAME side: a mapped name is only mapped when the provide carries
        # a VERSION — one finding per provide, because the fix is the same
        # declaration the constraint rule below asks for, and a second finding
        # would only double-count the same edit. A provide of an output name
        # is a compat map only when some carrying output is named differently:
        # a package providing its own name routes nothing, exactly like a
        # capability virtual.
        set -l mapped 0
        if contains -- "$id|$name" $mapping
            set mapped 1
        else if contains -- "$name" $output_names
            if test -n "$carrier"
                test "$carrier" != "$name"; and set mapped 1
            else
                for ro in $recipe_outputs
                    set -l rop (string split -m 1 '|' -- $ro)
                    test "$rop[1]" = "$id"; or continue
                    if test "$rop[2]" != "$name"
                        set mapped 1
                        break
                    end
                end
            end
        end
        if test $mapped -eq 1
            if test -z "$ver"
                set -a findings "provides: $id: mapped swap/compat provide '$name' is unversioned — declare provides=('$name=\${pkgver}') so versioned dependents of the mapped name resolve here"
            end
            continue
        end
        # A versioned name-provide satisfies its own version; only an
        # UNVERSIONED provide falls back to the repo package.
        test -z "$ver"; or continue
        for c in $constraints
            set -l cp (string split '|' -- $c)
            test "$cp[1]" = "$name"; or continue
            set -a findings "provides: $id: unversioned provide '$name' cannot satisfy '$name$cp[2]$cp[3]' (required by $cp[4]) — version it as provides=('$name=\${pkgver}')"
        end
    end
    if test (count $findings) -gt 0
        printf '%s\n' $findings | sort -u
    end
    return 0
end

function audit_lint_purged
    # The purged set docs/MEMORY.md rule 8 keeps out of build-time fields.
    set -l denylist po4a python-sphinx python-myst-parser lvm2 libblockdev-lvm systemd-tests cuda gcc15
    set -l findings
    # The shared .SRCINFO parse (srcinfo_rows D) replaces the per-recipe
    # tagged sed pair — one workspace read instead of one fork per recipe.
    # The empty-value guard replicates the old substitution's empty-line drop;
    # findings sort -u at the end, so row order is output-invisible.
    for row in (srcinfo_rows D)
        set -l parts (string split -m 2 '|' -- "$row")
        contains -- "$parts[2]" makedepends checkdepends; or continue
        test -n "$parts[3]"; or continue
        set -l id "$parts[1]"
        set -l field "$parts[2]"
        set -l value "$parts[3]"
        set -l v (string split -m1 ':' -- "$value")[1]
        set -l m (string match -r -g '^(.+?)(>=|<=|=|>|<)(.+)$' -- (string trim -- $v))
        set -l name $v
        test (count $m) -ge 3; and set name $m[1]
        if contains -- "$name" $denylist
            set -a findings "purged: $id: $field reintroduces purged tool '$name' — remove it (docs/MEMORY.md rule 8)"
        end
    end
    if test (count $findings) -gt 0
        printf '%s\n' $findings | sort -u
    end
    return 0
end

# ─── AUTO-REGISTER: the IgnorePkg mutation seam ──────────────────────────────
# IgnorePkg is DYNAMIC since 2026-10-05: the install pipeline registers each
# accepted archive's names at install time (register_ignorepkg_names below),
# and `--register-ignorepkg [conf]` (dispatcher at the bottom of
# build-all.fish) remains as the one-shot backfill over the whole workspace
# universe (pkgbase + every pkgname of each committed .SRCINFO — never a
# PKGBUILD grep, the kernel hides its names). Both paths share ONE write core:
# append the missing names as cumulative `IgnorePkg =` lines (~10 names/line)
# INSIDE [options] — after the last existing IgnorePkg line there, or before
# the next section header. Idempotent: a complete closure appends nothing.
# AUTO-REGISTER never auto-trusts — it REFUSES (rc 1, nothing changed) when
# the name set cannot be verified (a missing/stale .SRCINFO is NAMED and
# blocks the backfill write), or on a target that is not user-writable when
# `sudo -n` is unavailable (the builder NEVER prompts). The static closure
# lint that used to pair with this seam is RETIRED (2026-10-05): the contract
# is now "registered at install time", not "pre-listed in the host conf".
#
# pacman_conf_ignorepkg_walk CONF — THE pacman.conf parser for the seam (the
# lint above parses the same grammar for its report; this walk adds the
# mutation-side derivations). Semantics are pacman's: `IgnorePkg =` lines
# accumulate, whitespace-split, only inside [options]; a line inside a repo
# section — or before any section header — is dropped (a repo-section drop is
# LOUD here, a pre-section drop is silently pacman's own behaviour). Emits
# one tagged line per observation:
#   ignored <name>             one name in the cumulative [options] closure
#   repo-drop <TAB>line<TAB>sec  IgnorePkg inside repo section <sec> (dropped)
#   options-include <line>     an Include inside [options] (closure unfollowable)
#   insert-before <line>       splice point for new lines (0 = append at EOF)
#   no-options                 the conf has no [options] section at all
function pacman_conf_ignorepkg_walk -a conf
    set -l in_options 0
    set -l sec ''
    set -l lineno 0
    set -l last_ignore 0
    set -l options_seen 0
    set -l insert_before 0
    for raw in (cat "$conf")
        set lineno (math $lineno + 1)
        set -l line (string trim -- (string split -m1 '#' -- "$raw")[1])
        test -n "$line"; or continue
        if string match -qr '^\[.+\]$' -- "$line"
            set sec (string trim -- (string replace -r '^\[(.+)\]$' '$1' -- "$line"))
            if test "$sec" = options
                set in_options 1
                set options_seen 1
            else
                # First non-[options] header after [options]: the fallback
                # splice point when [options] carries no IgnorePkg line yet.
                if test $options_seen -eq 1; and test $insert_before -eq 0
                    set insert_before $lineno
                end
                set in_options 0
            end
            continue
        end
        if string match -qr '^IgnorePkg[[:space:]]*=' -- "$line"
            if test $in_options -eq 1
                set last_ignore $lineno
                set -l m (string match -r -g '^IgnorePkg[[:space:]]*=[[:space:]]*(.*)$' -- "$line")
                test (count $m) -ge 1; or continue
                for name in (string split -n ' ' -- (string replace -a \t ' ' -- $m[1]))
                    echo "ignored $name"
                end
            else if test -n "$sec"
                printf 'repo-drop\t%s\t%s\n' "$lineno" "$sec"
            end
            continue
        end
        if test $in_options -eq 1; and string match -qr '^Include[[:space:]]*=' -- "$line"
            echo "options-include $lineno"
        end
    end
    if test $options_seen -eq 0
        echo "no-options"
        return 0
    end
    if test $last_ignore -gt 0
        echo "insert-before "(math $last_ignore + 1)
    else
        echo "insert-before $insert_before"
    end
end

# register_ignorepkg_names CONF SUBJECT NAMES... [-- FINDING...] — the ONE
# names-driven write core, shared by the install pipeline's dynamic
# registration (build-all.fish's install_register_ignorepkg) and the
# --register-ignorepkg backfill wrapper below. Appends the NAMES the CONF's
# [options] closure does not cover as cumulative `IgnorePkg =` lines and
# verifies the result. SUBJECT is the phrase the report lines use to say
# whose names these are ("universe N name(s) from M recipe(s)" for the
# backfill, "N name(s) from M archive(s)" for the install path); FINDING...
# (after a literal `--`) are caller-side findings that block the write
# exactly like the walk's own. rc 0 = the closure covers NAMES afterwards
# (nothing-to-append counts), 1 = refusal (nothing changed, or the post-check
# caught a write that did not land), 2 = usage is the dispatcher's job.
function register_ignorepkg_names -a conf subject
    set -l rest $argv[3..-1]
    set -l names $rest
    set -l findings
    if set -l sep (contains -i -- -- $rest)
        set names $rest[1..(math $sep - 1)]
        set findings $rest[(math $sep + 1)..-1]
    end
    test -n "$conf"; or set conf /etc/pacman.conf

    if test (count $names) -gt 0
        set names (printf '%s\n' $names | sort -u)
    end

    # ── parse the target exactly like pacman (the walk) ──────────────────
    if not test -r "$conf"
        echo "register-ignorepkg: cannot read $conf — nothing changed" >&2
        return 1
    end
    set -l walk (pacman_conf_ignorepkg_walk "$conf")
    set -l ignored
    set -l repo_drops
    set -l options_includes
    set -l insert_before -1
    if test (count $walk) -gt 0
        set ignored (string match -r -g '^ignored (.+)$' -- $walk)
        set repo_drops (string match -r -g '^repo-drop\t(.+)$' -- $walk)
        set options_includes (string match -r -g '^options-include ([0-9]+)$' -- $walk)
        set -l ib (string match -r -g '^insert-before ([0-9]+)$' -- $walk)
        test (count $ib) -ge 1; and set insert_before $ib[1]
    end
    for drop in $repo_drops
        set -l parts (string split \t -- $drop)
        echo "register-ignorepkg: warning: $conf line $parts[1]: IgnorePkg inside repo section [$parts[2]] is dropped by pacman — move it into [options]"
    end
    for line in $options_includes
        set -a findings "$conf line $line: [options] Include is not followed — inline its IgnorePkg entries into the file"
    end
    if test $insert_before -lt 0
        set -a findings "$conf: no [options] section — IgnorePkg lines have nowhere to live"
    end
    if test (count $ignored) -gt 0
        set ignored (printf '%s\n' $ignored | sort -u)
    end

    if test (count $findings) -gt 0
        for finding in $findings
            echo "register-ignorepkg: finding: $finding" >&2
        end
        echo "register-ignorepkg: $subject, closure "(count $ignored)" name(s) before, not modified" >&2
        echo "register-ignorepkg: refusing to modify $conf — fix the findings first" >&2
        return 1
    end

    # ── 3. missing set: the universe names the closure does not cover ────
    set -l missing
    for name in $names
        contains -- "$name" $ignored; or set -a missing "$name"
    end

    # ── 4. write path (only when something is missing) ───────────────────
    # Escalate with sudo -n ONLY — the builder never prompts: a dead
    # credential fails fast with nothing changed. A user-writable target
    # (every fixture path) never touches sudo at all.
    if test (count $missing) -gt 0
        set -l need_sudo 0
        if not test -w "$conf"; or not test -w (dirname -- "$conf")
            set need_sudo 1
        end
        if test $need_sudo -eq 1
            if not sudo -n true 2>/dev/null
                echo "register-ignorepkg: sudo cannot modify $conf non-interactively — nothing changed" >&2
                return 1
            end
        end
        # Dated pre-image backup before the first modification. An existing
        # identical backup is left alone (crash-window recovery); a differing
        # one is never overwritten — it is the day's original pre-image.
        set -l backup "$conf.bak-"(date +%Y%m%d)
        if test -e "$backup"
            if command cmp -s -- "$conf" "$backup"
                echo "register-ignorepkg: backup $backup already present (identical pre-image)"
            else
                # The dated file is the day's ORIGINAL pre-image: kept as the
                # restore point, never rewritten, and never a reason to refuse
                # (2026-10-05). The dynamic install-time registration runs on
                # EVERY install, so a backup that differs from the conf is the
                # normal state after the first write of the day — the earlier
                # refusal made every later registration fail on it.
                echo "register-ignorepkg: backup $backup already present (kept as the day's pre-image)"
            end
        else if test $need_sudo -eq 1
            if not sudo -n cp -p -- "$conf" "$backup"
                echo "register-ignorepkg: cannot write backup $backup — nothing changed" >&2
                return 1
            end
            echo "register-ignorepkg: backup $backup (pre-image)"
        else
            if not command cp -p -- "$conf" "$backup"
                echo "register-ignorepkg: cannot write backup $backup — nothing changed" >&2
                return 1
            end
            echo "register-ignorepkg: backup $backup (pre-image)"
        end
        # ~10 names per cumulative line, in the universe's sorted order.
        set -l new_lines
        set -l idx 1
        set -l total (count $missing)
        while test $idx -le $total
            set -l last (math $idx + 9)
            test $last -gt $total; and set last $total
            set -a new_lines "IgnorePkg = "(string join ' ' $missing[$idx..$last])
            set idx (math $idx + 10)
        end
        set -l tmpfile (mktemp)
        if test -z "$tmpfile"
            echo "register-ignorepkg: cannot allocate a scratch file — nothing changed" >&2
            return 1
        end
        if test $insert_before -gt 0
            command head -n (math $insert_before - 1) -- "$conf" >"$tmpfile"
            printf '%s\n' $new_lines >>"$tmpfile"
            command tail -n +"$insert_before" -- "$conf" >>"$tmpfile"
        else
            command cat -- "$conf" >"$tmpfile"
            # a conf without a trailing newline must not swallow the first
            # appended line
            if test (command tail -c 1 -- "$conf" | command wc -l) -eq 0
                printf '\n' >>"$tmpfile"
            end
            printf '%s\n' $new_lines >>"$tmpfile"
        end
        # NOTE: `set -l` is BLOCK-scoped in fish — cp_rc must be declared
        # outside the if/else below to survive its `end`.
        set -l cp_rc 0
        if test $need_sudo -eq 1
            sudo -n cp -- "$tmpfile" "$conf"
            set cp_rc $status
        else
            command cp -- "$tmpfile" "$conf"
            set cp_rc $status
        end
        command rm -f -- "$tmpfile"
        if test $cp_rc -ne 0
            echo "register-ignorepkg: cannot write $conf" >&2
            return 1
        end
        echo "register-ignorepkg: $subject, closure "(count $ignored)" name(s) before, appended $total name(s) as "(count $new_lines)" IgnorePkg line(s)"
    else
        echo "register-ignorepkg: $subject, closure "(count $ignored)" name(s) before, no changes needed"
    end

    # ── 5. post-condition: comm -23(universe, closure-after) must be empty ─
    # The verification RE-READS the file through the same pacman parser — the
    # write is only done when the closure it ships is provably complete.
    set -l walk_after (pacman_conf_ignorepkg_walk "$conf")
    set -l ignored_after
    if test (count $walk_after) -gt 0
        set ignored_after (string match -r -g '^ignored (.+)$' -- $walk_after)
    end
    set -l scratch (mktemp -d)
    if test -n "$scratch"
        if test (count $names) -gt 0
            printf '%s\n' $names | sort -u >"$scratch/universe"
        else
            printf '' >"$scratch/universe"
        end
        if test (count $ignored_after) -gt 0
            printf '%s\n' $ignored_after | sort -u >"$scratch/closure"
        else
            printf '' >"$scratch/closure"
        end
        set -l missing_after (command comm -23 "$scratch/universe" "$scratch/closure")
        command rm -rf -- "$scratch"
        if test (count $missing_after) -eq 0
            echo "register-ignorepkg: verification comm -23 (universe vs closure after): empty"
            return 0
        end
        echo "register-ignorepkg: verification comm -23 (universe vs closure after):"
        printf '%s\n' $missing_after
        return 1
    end
    echo "register-ignorepkg: cannot allocate scratch for the verification — re-run to verify" >&2
    return 1
end

# register_ignorepkg CONF — the --register-ignorepkg backfill: compute the
# workspace name universe, append the missing names to CONF's [options] and
# verify the result, through the names-driven core above. rc 0 = the closure
# is complete afterwards (nothing-to-append counts), 1 = refusal (nothing
# changed, or the post-check caught a write that did not land), 2 = usage is
# the dispatcher's job. See the seam comment at the bottom of build-all.fish.
function register_ignorepkg -a conf
    test -n "$conf"; or set conf /etc/pacman.conf

    # ── 1. workspace pkgname universe: every recipe's committed .SRCINFO ──
    # Recipe dirs live at packages/<group>/<name> (a synthetic workspace may
    # put them one level up); a directory is a recipe when it carries PKGBUILD
    # or .SRCINFO. Missing or stale .SRCINFO is a NAMED finding that blocks:
    # registering a closure computed over a hole would print "empty missing
    # set" while some outputs stay unprotected.
    set -l names
    set -l findings
    set -l recipe_count 0
    for dir in $SCRIPT_DIR/packages/* $SCRIPT_DIR/packages/*/*
        test -d "$dir"; or continue
        if not test -f "$dir/PKGBUILD"; and not test -f "$dir/.SRCINFO"
            continue
        end
        set recipe_count (math $recipe_count + 1)
        set -l rel (string replace -- "$SCRIPT_DIR/" '' "$dir")
        set -l srcinfo "$dir/.SRCINFO"
        if not test -f "$srcinfo"
            set -a findings "$rel: no .SRCINFO committed"
            continue
        end
        # D-F5: the name parse runs through the shared srcinfo_* helpers —
        # the same field rules every other consumer uses (srcinfo_output_names
        # is the OUTPUTS half of the one name surface, pkgbase its base half).
        set -l si_base (srcinfo_pkgbase "$srcinfo")
        set -l si_out (srcinfo_output_names "$srcinfo")
        if test (count $si_base) -eq 0; or test (count $si_out) -eq 0
            set -a findings "$rel: stale .SRCINFO (pkgbase/pkgname entries missing — regenerate with GIT_CONFIG_COUNT=0 makepkg --printsrcinfo > .SRCINFO)"
            continue
        end
        # Stale the way bettbox was stale (docs/MEMORY.md): the PKGBUILD
        # declares a LITERAL pkgver/pkgrel/epoch the committed .SRCINFO
        # contradicts. Only plain literals are compared — a computed value
        # (the kernel's pkgver=$_basekernver) is uncheckable text, and the
        # full makepkg --printsrcinfo diff is tests/srcinfo-freshness.sh's job.
        # The scan matches the field ANYWHERE in the file, not just the
        # pkgbase section the srcinfo_* base helpers read: a literal that
        # drifted into another section is exactly this drift class, and the
        # helpers' early stop would miss it (tests/ignorepkg-register.sh i).
        set -l si (cat "$srcinfo")
        set -l pb
        if test -f "$dir/PKGBUILD"
            set pb (cat "$dir/PKGBUILD")
        end
        for field in epoch pkgver pkgrel
            set -l pb_val ''
            for raw in $pb
                set -l m (string match -r -g "^$field=(.+)\$" -- "$raw")
                test (count $m) -ge 1; or continue
                set pb_val (string trim -c "\"'" -- $m[1])
                break
            end
            test -n "$pb_val"; or continue
            string match -qr '^[0-9A-Za-z._:+~>-]+$' -- "$pb_val"; or continue
            set -l siv ''
            if test (count $si) -gt 0
                set -l s (string match -r -g "^$field = (.+)\$" -- $si)
                test (count $s) -ge 1; and set siv $s[1]
            end
            test -n "$siv"; or continue
            if test "$pb_val" != "$siv"
                set -a findings "$rel: stale .SRCINFO ($field is $pb_val in PKGBUILD but $siv in .SRCINFO — regenerate with GIT_CONFIG_COUNT=0 makepkg --printsrcinfo > .SRCINFO)"
            end
        end
        for name in $si_base $si_out
            test -n "$name"; and set -a names "$name"
        end
    end
    if test $recipe_count -eq 0
        set -a findings "no recipe directories under $SCRIPT_DIR/packages — nothing to register"
    end
    if test (count $names) -gt 0
        set names (printf '%s\n' $names | sort -u)
    end

    set -l subject "universe "(count $names)" name(s) from $recipe_count recipe(s)"
    register_ignorepkg_names "$conf" "$subject" $names -- $findings
end

function audit_lint_swap
    set -l findings
    # ONE shared .SRCINFO parse (srcinfo_rows) replaces the per-recipe section
    # walk: a `pkgbase`/`pkgname` line switches the section and every indented
    # field belongs to the section above it, so each provide/conflicts row
    # carries its section handle ('' = the pkgbase section, whose metadata
    # makepkg merges into every output — cmake-git's shape) and the section
    # name stays on the recipe walk for the empty-entry findings. Entries are
    # stored as handle|name with the version suffix already stripped, so
    # `provides = cmake=4.4.3…` matches `cmake`. Rows arrive grouped per
    # recipe in $_PACKAGE_MAP order; the trailing sentinel row flushes the
    # last recipe through the same branch a recipe change takes. Findings end
    # `sort -u`, so walk order is output-invisible.
    set -l row_id ''
    set -l section '' # the current section name, for the empty-entry findings
    set -l outputs
    set -l provide_keys
    set -l conflict_keys
    for row in (srcinfo_rows) '__flush__|'
        set -l parts (string split -m 3 '|' -- "$row")
        set -l id $parts[2]
        if test "$id" != "$row_id"
            if test -n "$row_id"
                for name in $outputs
                    set -l stock (string replace -r -- '-(git|svn|hg|snapshot)$' '' "$name")
                    if test "$stock" = "$name"
                        continue
                    end
                    # A soname-shaped counterpart (`libfoo.so…`) is a provide of a
                    # library, never a stock package name — nothing to swap.
                    if string match -q '*.so*' -- "$stock"
                        continue
                    end
                    if not contains -- "|$stock" $provide_keys; and not contains -- "$name|$stock" $provide_keys
                        set -a findings "swap: $name: stock counterpart '$stock' missing from provides — declare provides=('$stock=\${pkgver}')"
                    end
                    if not contains -- "|$stock" $conflict_keys; and not contains -- "$name|$stock" $conflict_keys
                        set -a findings "swap: $name: stock counterpart '$stock' missing from conflicts — declare conflicts=('$stock')"
                    end
                end
            end
            test "$id" = ''; and break
            set row_id "$id"
            set section ''
            set outputs
            set provide_keys
            set conflict_keys
        end
        switch $parts[1]
            case B
                set section "$parts[3]"
            case N
                set section "$parts[3]"
                set -a outputs "$parts[3]"
            case P
                if test -z "$parts[4]"
                    set -a findings "swap: $section: empty provides entry — declare the stock counterpart or drop the entry"
                else
                    set -a provide_keys "$parts[3]|"(string replace -r '[=<>].*$' '' -- "$parts[4]")
                end
            case C
                if test -z "$parts[4]"
                    set -a findings "swap: $section: empty conflicts entry — declare the stock counterpart or drop the entry"
                else
                    set -a conflict_keys "$parts[3]|"(string replace -r '[=<>].*$' '' -- "$parts[4]")
                end
        end
    end
    if test (count $findings) -gt 0
        printf '%s\n' $findings | sort -u
    end
    return 0
end

# ─── Workspace audit (--audit) ───────────────────────────────────────────────
# Read-only inventory of migration drift. Historical NOTE.md entries and large
# source/build trees are reported separately from active control-file findings.
function audit_workspace
    # `strings`/`xargs` back the installed-PGO-payload scan; without them that
    # section would report a clean result it never actually measured.
    for tool in rg strings xargs mktemp
        require_command $tool; or return 1
    end

    ui_heading "Workspace legacy audit"
    echo ""
    # ONE pass over everything a maintainer can edit. The pre-Git workspace
    # split recipes across top-level .Stable/.Heavy/.Static/.Core/.Misc/.3rdP
    # directories; any surviving mention of one is drift. config/ and docs/ are
    # excluded: config/ is validated structurally at load time, and NOTE.md is
    # a historical journal that is *expected* to name the old layout.
    echo "Legacy layout references:"
    set -l refs (rg -n --hidden \
        --glob '!docs/**' --glob '!build-all.fish' --glob '!config/**' \
        --glob '!**/.state/**' --glob '!**/.git/**' \
        --glob '!**/src/**' --glob '!**/pkg/**' --glob '!**/build/**' \
        '(^|[^[:alnum:]_])\.(Stable|Static|Heavy|Heavyweight|Core|Misc|3rdP)/' \
        "$SCRIPT_DIR" 2>/dev/null | head -100)
    if test (count $refs) -eq 0
        echo "  none"
    else
        for ref in $refs
            echo "  $ref"
        end
    end

    set -l listed
    for group_name in $_GROUP_NAMES
        set -l mangled (string replace - _ -- "$group_name")
        set -l var_name "_GROUP_$mangled"
        set -a listed $$var_name
    end
    set listed (printf '%s\n' $listed | awk '!seen[$0]++')
    set -l actual $_PACKAGE_IDS
    set -l unlisted
    for d in $actual
        if not contains "$d" $listed
            set -a unlisted $d
        end
    end
    set -l missing
    for d in $listed
        if not contains "$d" $actual
            set -a missing $d
        end
    end

    echo ""
    echo "Package membership drift:"
    if test (count $unlisted) -eq 0
        echo "  unlisted: none"
    else
        echo "  unlisted:"
        for d in $unlisted
            echo "    $d"
        end
    end
    if test (count $missing) -eq 0
        echo "  listed-but-missing: none"
    else
        echo "  listed-but-missing:"
        for d in $missing
            echo "    $d"
        end
    end

    set -l bad_deps
    for entry in $_DEPS
        set -l parts (string split ':' $entry -m 2)
        set -l pkg $parts[1]
        if not contains "$pkg" $actual
            set -a bad_deps "$pkg (package missing)"
        end
        if test (count $parts) -ge 2 -a -n "$parts[2]"
            for dep in (string split ',' $parts[2])
                if not contains "$dep" $actual
                    set -a bad_deps "$pkg -> $dep"
                end
            end
        end
    end
    echo ""
    echo "Dependency graph:"
    if test (count $bad_deps) -eq 0
        echo "  all package and dependency paths resolve"
    else
        for dep in $bad_deps
            echo "  $dep"
        end
    end

    # Toolchain lint (2026-09-25 ABI-skew incident): a recipe that compiles
    # with cargo/rustc only survives a coupled LLVM batch when rust-git
    # rebuilds BEFORE it, so its topology record's edges field must name
    # rust-git explicitly. rust-git is the toolchain itself and cannot depend
    # on its own output, so it is excepted. "Invokes" = any non-comment line
    # (first non-blank character is not '#') naming cargo or rustc as a bare
    # word; comment-only mentions are history, not toolchain use.
    echo ""
    echo "Toolchain (cargo/rustc) dependency edges:"
    set -l toolchain_missing
    # The shared PKGBUILD parse (pkgbuild_scan_rows W) replaces the two grep
    # forks per recipe; the rust-edge check reads the topology records as
    # before.
    for row in (pkgbuild_scan_rows W)
        set -l parts (string split -m 1 '|' -- "$row")
        set -l id $parts[1]
        test "$id" = rust-git; and continue
        test "$parts[2]" -gt 0; or continue
        set -l has_rust_edge 0
        for dep_entry in $_DEPS
            set -l dep_fields (string split ':' $dep_entry -m 2)
            if test "$dep_fields[1]" = "$id"; and test (count $dep_fields) -ge 2
                for dep in (string split ',' $dep_fields[2])
                    test "$dep" = rust-git; and set has_rust_edge 1
                end
            end
        end
        test $has_rust_edge -eq 1; and continue
        set -a toolchain_missing $id
    end
    if test (count $toolchain_missing) -eq 0
        echo "  none"
    else
        for id in $toolchain_missing
            echo "  toolchain: $id uses cargo/rustc but declares no rust-git edge"
        end
    end

    # Recipe-contract lints (one implementation per rule — the functions above;
    # the hidden --audit-lint seam runs them individually). Report-only here:
    # findings never changed this audit's exit status and must not start now.
    echo ""
    echo "Provides versioning:"
    set -l provides_findings (audit_lint_provides)
    if test (count $provides_findings) -eq 0
        echo "  none"
    else
        for finding in $provides_findings
            echo "  $finding"
        end
    end

    echo ""
    echo "Purged tools:"
    set -l purged_findings (audit_lint_purged)
    if test (count $purged_findings) -eq 0
        echo "  none"
    else
        for finding in $purged_findings
            echo "  $finding"
        end
    end

    echo ""
    echo "Stock→house swap:"
    set -l swap_findings (audit_lint_swap)
    if test (count $swap_findings) -eq 0
        echo "  none"
    else
        for finding in $swap_findings
            echo "  $finding"
        end
    end

    # ABI-drift guard layers 1 + 5 (report-only here exactly like the
    # recipe-contract lints above; the hidden --audit-lint seam runs them
    # individually as abi-closure / abi-exposure).
    echo ""
    echo "ABI closure (workspace-built outputs):"
    set -l closure_findings (audit_lint_abi_closure)
    if test (count $closure_findings) -eq 0
        echo "  none"
    else
        for finding in $closure_findings
            echo "  $finding"
        end
    end

    echo ""
    echo "ABI exposure (soname provides vs installed stock):"
    set -l exposure_findings (audit_lint_abi_exposure)
    if test (count $exposure_findings) -eq 0
        echo "  none"
    else
        for finding in $exposure_findings
            echo "  $finding"
        end
    end

    echo ""
    echo "Stale runtime/error artifacts:"
    # Scope mirrors sweep_stale_run_artifacts exactly: recursive over
    # $_STATE_DIR (toolchain records live in a subdir), the same name classes,
    # the same packages-tree exclusions — audit and sweep must never drift.
    set -l stale (find "$_STATE_DIR" -type f \
        \( -name '.lane*.result' -o -name '*.tmp.*' -o -name '*.srcinfo.err' \) \
        -printf '%p\n' 2>/dev/null)
    if test (count $stale) -eq 0
        echo "  none"
    else
        for path in $stale
            echo "  $path"
        end
    end
    set -l package_errors (find "$SCRIPT_DIR/packages" \
        \( -name '.srcinfo.err' -o -name '*.gsa-vcs-revisions.tmp.*' \) \
        -not -path '*/src/*' -not -path '*/pkg/*' -not -path '*/build/*' \
        -printf '%p\n' 2>/dev/null)
    for path in $package_errors
        if not contains "$path" $stale
            echo "  $path"
        end
    end

    echo ""
    echo "Installed PGO payloads:"
    # An installed binary that still carries -fprofile-generate or
    # -Cprofile-generate is the one
    # PGO defect the recipe-level check cannot see: it fails only on machines
    # that do not have the instrumenting build's directory tree.  The builder
    # refuses such an archive at install time (the install plan's PGO gate,
    # pgo_payload_refusals), but an
    # install made *before* that gate existed stays broken until rebuilt, so
    # the audit reports it.  Every file is scanned rather than the obvious
    # usr/bin+usr/lib pair, because scoping to those embeds an assumption
    # about where a recipe installs its binaries.  Archive metadata is not a
    # false-positive source here: the predicate matches a `.gcda`/`.profraw`
    # path, not the instrumenting flag that `.BUILDINFO` happens to record.
    set -l pgo_names
    # The shared parses replace the per-recipe forks: pkgbuild_scan_rows G is
    # the instrumenting-flag grep, the N rows the .SRCINFO pkgname sweep.
    # Names come from .SRCINFO, never PKGBUILD: the kernel assigns pkgbase
    # in a variable, so PKGBUILD scraping would misreport it as absent.
    set -l pgo_ids
    for row in (pkgbuild_scan_rows G)
        set -a pgo_ids (string split -m 1 '|' -- "$row")[1]
    end
    for row in (srcinfo_rows N)
        set -l parts (string split -m 1 '|' -- "$row")
        contains -- "$parts[1]" $pgo_ids; and set -a pgo_names "$parts[2]"
    end
    if test (count $pgo_names) -gt 0
        set pgo_names (printf '%s\n' $pgo_names | awk '!seen[$0]++')
    end
    set -l pgo_list (mktemp 2>/dev/null)
    set -l pgo_absent
    if test -n "$pgo_list"; and test (count $pgo_names) -gt 0
        # F7: ONE `pacman -Ql` for the whole name list instead of a probe +
        # list pair per name. stderr's not-found lines are the absent set
        # (restored to pgo_names order below — the report lists them in recipe
        # order) and every resolvable name contributes its file rows exactly
        # as the per-name call did.
        set -l ql_err (mktemp 2>/dev/null)
        LANG=C pacman -Ql -- $pgo_names 2>"$ql_err" | awk '$2 !~ /\/$/ {print $2}' > $pgo_list
        for line in (cat $ql_err 2>/dev/null)
            set -l m (string match -r -g "^error: package '(.+)' was not found\$" -- "$line")
            if test (count $m) -ge 1
                contains -- "$m[1]" $pgo_absent; or set -a pgo_absent "$m[1]"
            end
        end
        command rm -f -- "$ql_err"
        set -l ordered
        for name in $pgo_names
            contains -- "$name" $pgo_absent; and set -a ordered "$name"
        end
        set pgo_absent $ordered
    end
    if test (count $pgo_absent) -gt 0
        echo "  not installed (not inspected): "(string join ' ' $pgo_absent)
    end
    # Fail closed: a scan that read no files would otherwise report "none".
    set -l pgo_files 0
    test -n "$pgo_list"; and set pgo_files (count (cat $pgo_list))
    if test -z "$pgo_list" -o "$pgo_files" -eq 0
        echo "  unable to enumerate installed files — payload check skipped"
    else
        echo "  inspected $pgo_files files from "(count $pgo_names)" PGO recipes"
        set -l pgo_hits (xargs -d'\n' -r -n 400 strings -a -f < $pgo_list 2>/dev/null \
            | grep -E '^[^:]+: /[^[:space:]/*][^[:space:]]*\.(gcda|profraw)' | cut -d: -f1 | sort -u)
        if test (count $pgo_hits) -eq 0
            echo "  none carry baked .gcda/.profraw paths"
        else
            for hit in $pgo_hits
                echo "  $hit"
            end
        end
    end
    test -n "$pgo_list"; and command rm -f $pgo_list

    echo ""
    echo "Historical references in docs/NOTE.md are not treated as active"
    echo "configuration by this audit."
end

