#!/usr/bin/env fish
# build-all.fish — Workspace package builder with dependency ordering
# Builds and optionally installs Arch Linux packages from PKGBUILDs in this workspace.

set -g SCRIPT_DIR (realpath (status dirname))
set -g CONFIG_DIR "$SCRIPT_DIR/config"
# One topology file: per-package records (id|path|groups|edges[|tags]) replace
# the former packages.map + groups/*.list + dependencies.conf trio (2026-09-26).
set -g TOPOLOGY_FILE "$CONFIG_DIR/topology.conf"
set -g DEFAULT_CONFIG_FILE "$CONFIG_DIR/build-defaults.conf"
set -g _STATE_DIR "$SCRIPT_DIR/.state"
if set -q GSA_STATE_DIR; and test -n "$GSA_STATE_DIR"
    set -g _STATE_DIR "$GSA_STATE_DIR"
end
set -g LOG_DIR "$_STATE_DIR/logs"

# ─── Identity: root supervises, the invoking user builds ─────────────────
# Root-mode (sudo fish build-all.fish ...): installs run directly as root
# (no sudo timestamp to expire on long runs); makepkg + ALL workspace
# artifacts run as the invoking user — makepkg refuses root, and --asroot
# would scatter root-owned src/pkg files into the checkout plus root caches
# (~/.ccache, ~/.cargo, ~/.cache/go-build) into /root. Ownership is settled
# at WRITE time: ensure_state_dirs sweeps $_STATE_DIR at startup, every
# runtime-state file open goes through ensure_log_writable, and build_package
# still chowns the recipe tree + LOG_DIR at exit — so nothing root-owned
# survives even a run killed mid-flight. (Repair only at exit had a crash
# window: 2026-09-23, six root-owned logs aborted the next unprivileged run
# at rc=125 before its builds even started.) Unprivileged mode: everything as
# before (sudo -n installs).
set -g _BUILD_USER (id -un)
set -g _ROOT_MODE 0
if test "$_BUILD_USER" = "root"
    if test -n "$SUDO_USER"; and test "$SUDO_USER" != "root"
        set -g _BUILD_USER "$SUDO_USER"
        set -g _ROOT_MODE 1
    else
        echo "Error: run as your normal user, or via 'sudo fish build-all.fish ...'"
        echo "(bare root has no invoking user to build as — makepkg refuses root)"
        exit 1
    end
end
set -g _BUILD_HOME ""
if command -v getent >/dev/null 2>&1
    set _BUILD_HOME (getent passwd "$_BUILD_USER" | cut -d: -f6)
end
if test -z "$_BUILD_HOME"; and test -n "$HOME"
    set _BUILD_HOME "$HOME"
end
if test -z "$_BUILD_HOME"
    echo "Error: cannot resolve the home directory for $_BUILD_USER"
    exit 1
end
# 1 = background lane job — suppress human-facing echoes (the parent renderer
# owns live output). Set per-build_package call; the install pipeline does NOT
# read it — install_pkgs_now receives its sink/mode as arguments.
set -g _BUILD_QUIET 0

# Output is rendered by the parent dispatcher only. Fish's set_color emits
# ANSI sequences even when stdout is a pipe, so wrap the builtin and make
# colors follow the actual output destination.
set -g _OUTPUT_INTERACTIVE 0
if test -t 1; and test -n "$TERM"; and test "$TERM" != "dumb"
    set -g _OUTPUT_INTERACTIVE 1
end
function set_color
    if test "$_OUTPUT_INTERACTIVE" = "1"
        builtin set_color $argv
    end
end

# Because that wrapper is *empty* off a terminal, text must never ride in the
# same word as its escapes: fish drops a whole word like
# `(set_color cyan)"text"(set_color normal)` when the substitution yields
# nothing, so `echo` printed a blank line in a pipe — and the pipe is the
# documented interface to parse. Write such lines as
# `printf '%s%s%s\n' (set_color cyan) "text" (set_color normal)`, where the
# text is its own argument and survives either way.

set -g _UI_ICON_OK "✓"
set -g _UI_ICON_ERROR "✗"
set -g _UI_ICON_WARN "⚠"
set -g _UI_ICON_INFO "·"
set -g _UI_ICON_ACTIVE "→"
set -g _PACMAN_MUTEX "$LOG_DIR/.pacman-install.lock"
set -g _PACMAN_MUTEX_WAIT 300
# Downloaded remote archives: what `-ccc`/`--nuclear` deletes and what the root
# .gitignore denies, as one list. A download lands *in the recipe directory*
# (makepkg's SRCDEST defaults to $startdir), so the two sets have to move
# together: drift one way and a sweep commits 36 MB of upstream archives (that
# happened — 2026-09-20, ten files in `libreoffice-fresh`); drift the other and
# `-ccc` leaves the next `.zip` behind to be committed the same way. Only
# URL-backed entries are ever matched, so a local patch, hook or keyring in the
# recipe directory is never a target, and `tests/recipe-sources.sh` fails rather
# than let a local asset vanish silently. Keep `.whl` here even though the
# gitignore spells it too — texlive-texmf downloads one.
# The wildcard entries are quoted on purpose: fish glob-expands an unquoted
# `tar.*` and drops it when nothing matches, which would silently shrink this
# list back to the old behaviour.
set -g _DOWNLOAD_ARCHIVE_EXTS tar 'tar.*' tgz zip jar ttf whl
# Unprivileged -i runs: the dispatcher refreshes the sudo cached credential so
# the lane installs (`sudo -n`, lane children have no tty) never need a
# password. The interval sits well inside the 5-min sudo timeout so a slow poll
# iteration under heavy CPU load cannot overshoot it (2026-09-07 llvm incident:
# a 70-min build whose keepalive prompt timed out). The builder NEVER prompts
# for a password (any privilege escalation is `sudo -n`): a dead credential
# fails fast instead of hanging an unattended run on a password nobody can
# type.
set -g _SUDO_KEEPALIVE_S 150

function ui_heading
    set -l prefix (set_color cyan)
    set -l suffix (set_color normal)
    set -l message (string join '' -- "━━━ " (string join ' ' -- $argv) " ━━━")
    echo "$prefix$message$suffix"
end

function ui_success
    set -l prefix (set_color green)
    set -l suffix (set_color normal)
    set -l message (string join '' -- "$_UI_ICON_OK " (string join ' ' -- $argv))
    echo "$prefix$message$suffix"
end

function ui_warning
    set -l prefix (set_color yellow)
    set -l suffix (set_color normal)
    set -l message (string join '' -- "$_UI_ICON_WARN " (string join ' ' -- $argv))
    echo "$prefix$message$suffix"
end

function ui_error
    set -l prefix (set_color red)
    set -l suffix (set_color normal)
    set -l message (string join '' -- "$_UI_ICON_ERROR " (string join ' ' -- $argv))
    echo "$prefix$message$suffix"
end

function ui_info
    echo "$_UI_ICON_INFO "(string join ' ' -- $argv)
end

set -g _ACTIVE_LANE_PIDS
# Package for the parallel _ACTIVE_LANE_PIDS entry at the same index — lets
# cleanup escalations land in the right package log (kept in lockstep by the
# dispatch append, forget_lane_pid and cleanup_active_lanes).
set -g _ACTIVE_LANE_PKGS
set -g _DASHBOARD_ROWS 0
set -g _DASHBOARD_ACTIVE 0
set -g _DASHBOARD_LAST_EVENT ""
set -g _DASHBOARD_LANE_BUSY
set -g _DASHBOARD_LANE_PKG
set -g _DASHBOARD_LANE_START
set -g _DASHBOARD_SPINNER_FRAMES '-' "\\" '|' '/'
set -g _DASHBOARD_SPINNER_INDEX 1
set -g _RL_BLOCKED 0
set -g _RL_DEFERRED
# ─── Lane outcome vocabulary (the result protocol's rc field) ───────────────
# The COMPLETE set of values a lane result's rc field may carry, and the only
# names code should ever compare against. lane_result_encode/decode (the codec
# pair beside write_lane_result) carry them across the process boundary; the
# dispatcher classifies with lane_outcome_name instead of re-deriving the
# numbers at every site. Two further numbers exist but are NOT outcomes: the
# --lane-job handler exits 2 on an invalid invocation (process rc only, no
# result row), and flock(1) surfaces 75 for a mutex timeout inside an install
# failure (which collapses to lane_outcome_failed like every other non-zero).
#   ok      0    build (and requested install) succeeded
#   failed  1    build or install failed — build_package collapses makepkg's
#                own rc to 1, so the compiler's number lives only in the log
#   defer   99   the lane PARKED the recipe and kept dispatching: anchoring
#                refused (build_package's anchor branch) or the -s freshness
#                refusal when upstream did not answer (rc-2 → defer,
#                2026-10-02 — reason travels as the wire's optional 4th
#                field, legacy writers default to anchoring-refused).
#                run_lanes turns it into a deferral instead of a failed
#                build; both sources return before makepkg ever runs.
#                Clear of flock's 75 and the lane-lost 125; no other path
#                emits it.
#   lost    125  lane supervisor produced no valid result (reap anomaly, or a
#                result write that failed)
#   hup     129  lane child killed by SIGHUP (honest result written first)
#   int     130  lane child killed by SIGINT
#   term    143  lane child killed by SIGTERM
set -g lane_outcome_ok 0
set -g lane_outcome_failed 1
set -g lane_outcome_defer 99
set -g lane_outcome_lost 125
set -g lane_outcome_hup 129
set -g lane_outcome_int 130
set -g lane_outcome_term 143
# Historical name kept as an alias: docs/MEMORY.md and the run-record cluster
# speak of "the _ANCHOR_DEFER_RC amendment"; the value has one home above.
set -g _ANCHOR_DEFER_RC $lane_outcome_defer

# lane_outcome_name RC → the enum's name for RC. Any number outside the
# vocabulary decodes as `failed` — the failure branch is the conservative
# default, never a silent success.
function lane_outcome_name -a rc
    switch "$rc"
        case "$lane_outcome_ok"
            echo ok
        case "$lane_outcome_defer"
            echo defer
        case "$lane_outcome_lost"
            echo lost
        case "$lane_outcome_hup"
            echo signal-hup
        case "$lane_outcome_int"
            echo signal-int
        case "$lane_outcome_term"
            echo signal-term
        case '*'
            echo failed
    end
end
set -g _INTERRUPT_HANDLED 0
# Signal forensics (2026-09-23 mass-TERM incident): which signal arrived, in
# which mode the handler ran, and how long lane teardown may grace before the
# single SIGKILL sweep — see gsa_handle_signal / stop_lane_process.
set -g _LAST_SIGNAL none
set -g _LANE_JOB_ACTIVE 0
set -g _LANE_SIGNAL_RC 0
# The grace defaults to 30 s but an exported value overrides it: an
# underscore-prefixed INTERNAL seam (tests/dashboard.sh shortens it so the
# post-grace KILL path can be proven in seconds). The seven public GSA_*
# inputs listed in --help are unchanged. Non-numeric junk falls back to 30.
if not set -q _LANE_STOP_GRACE_S; or not string match -qr '^[0-9]+$' -- $_LANE_STOP_GRACE_S
    set -g _LANE_STOP_GRACE_S 30
end

# ─── Project configuration ───────────────────────────────────────────────────
# The group roster is stated ONCE, here. Group membership lives in each
# topology record's groups field; only these five names are readable anywhere
# (loader validation, resolve_group, usage, diagnostics all derive from this
# list). Group variables are _GROUP_<name with '-' as '_'>.
# 2026-09-27: third-party retired — its members moved to app; `-g third-party`
# now fails through the unknown-group path (its members' recipes were never
# reachable through the group name again).
set -g _GROUP_NAMES git stable core misc app
set -g _PACKAGE_MAP
set -g _PACKAGE_IDS
set -g _DEPS
set -g _CONSUMER_INDEX
set -g _TAGS
set -g _GROUP_git
set -g _GROUP_stable
set -g _GROUP_core
set -g _GROUP_misc
set -g _GROUP_app
set -g _DEFAULT_LANES auto
set -g _DEFAULT_JOBS auto
set -g _DEFAULT_INTENSITY xhigh
set -g _MEMORY_PER_JOB_GIB 3
set -g _CORE_MEMORY_PER_JOB_GIB 4
set -g _RESERVED_MEMORY_GIB 2

function package_path -a package_id
    for entry in $_PACKAGE_MAP
        set -l fields (string split '|' -- "$entry")
        if test "$fields[1]" = "$package_id"
            echo "$SCRIPT_DIR/$fields[2]"
            return 0
        end
    end
    return 1
end

function package_id_for_path -a package_path_value
    set -l resolved (realpath "$package_path_value" 2>/dev/null)
    test -n "$resolved"; or return 1
    for entry in $_PACKAGE_MAP
        set -l fields (string split '|' -- "$entry")
        set -l known (realpath "$SCRIPT_DIR/$fields[2]" 2>/dev/null)
        if test "$known" = "$resolved"
            echo "$fields[1]"
            return 0
        end
    end
    return 1
end

function assign_group -a group_name
    set -l values $argv[2..-1]
    set -l mangled (string replace - _ -- "$group_name")
    set -g "_GROUP_$mangled" $values
    return 0
end

function intensity_is_valid -a intensity_level
    switch "$intensity_level"
        case low medium high xhigh max
            return 0
        case '*'
            return 1
    end
end

# Shared by --lanes and --jobs (identical accepted values, identical wording).
# The caller passes its own flag name so both flags keep their message.
function parallelism_is_valid -a flag value
    if test "$value" = auto
        return 0
    end
    if not string match -qr '^[0-9]+$' -- "$value"; or test "$value" -lt 1
        ui_error "$flag expects a positive integer or auto, got '$value'"
        return 1
    end
    return 0
end

function configure_intensity -a intensity_level
    if not intensity_is_valid "$intensity_level"
        ui_error "intensity must be one of low, medium, high, xhigh, or max"
        return 1
    end

    switch "$intensity_level"
        case low
            set -g _INTENSITY_LANE_CAP 1
            set -g _INTENSITY_CPU_PER_LANE 16
            set -g _INTENSITY_MEMORY_PER_LANE 16
            set -g _INTENSITY_NORMAL_MEMORY_FACTOR 2
            set -g _INTENSITY_CORE_MEMORY_FACTOR 1.5
        case medium
            set -g _INTENSITY_LANE_CAP 2
            set -g _INTENSITY_CPU_PER_LANE 8
            set -g _INTENSITY_MEMORY_PER_LANE 8
            set -g _INTENSITY_NORMAL_MEMORY_FACTOR 1
            set -g _INTENSITY_CORE_MEMORY_FACTOR 1
        case high
            set -g _INTENSITY_LANE_CAP 3
            set -g _INTENSITY_CPU_PER_LANE 6
            set -g _INTENSITY_MEMORY_PER_LANE 6
            set -g _INTENSITY_NORMAL_MEMORY_FACTOR 0.67
            set -g _INTENSITY_CORE_MEMORY_FACTOR 0.75
        case xhigh
            set -g _INTENSITY_LANE_CAP 4
            set -g _INTENSITY_CPU_PER_LANE 4
            set -g _INTENSITY_MEMORY_PER_LANE 4
            set -g _INTENSITY_NORMAL_MEMORY_FACTOR 0.5
            set -g _INTENSITY_CORE_MEMORY_FACTOR 0.625
        case max
            set -g _INTENSITY_LANE_CAP 6
            set -g _INTENSITY_CPU_PER_LANE 2
            set -g _INTENSITY_MEMORY_PER_LANE 2
            set -g _INTENSITY_NORMAL_MEMORY_FACTOR 0.34
            set -g _INTENSITY_CORE_MEMORY_FACTOR 0.5
    end
end

function read_config_defaults
    test -f "$DEFAULT_CONFIG_FILE"; or return 1
    for raw_line in (cat "$DEFAULT_CONFIG_FILE")
        set -l line (string trim -- "$raw_line")
        test -n "$line"; or continue
        string match -q '#*' -- "$line"; and continue
        set -l fields (string split -m 1 '=' -- "$line")
        test (count $fields) -eq 2; or return 1
        switch "$fields[1]"
            case lanes
                set -g _DEFAULT_LANES "$fields[2]"
            case jobs
                set -g _DEFAULT_JOBS "$fields[2]"
            case intensity
                set -g _DEFAULT_INTENSITY "$fields[2]"
            case memory_per_job_gib
                set -g _MEMORY_PER_JOB_GIB "$fields[2]"
            case core_memory_per_job_gib
                set -g _CORE_MEMORY_PER_JOB_GIB "$fields[2]"
            case reserved_memory_gib
                set -g _RESERVED_MEMORY_GIB "$fields[2]"
            case state_dir
                # State location is selected before config loading so an
                # explicit GSA_STATE_DIR always wins.
                if not set -q GSA_STATE_DIR; and test "$fields[2]" != auto
                    if string match -q '/*' -- "$fields[2]"
                        set -g _STATE_DIR "$fields[2]"
                    else
                        set -g _STATE_DIR "$SCRIPT_DIR/$fields[2]"
                    end
                    set -g LOG_DIR "$_STATE_DIR/logs"
                end
            case '*'
                return 1
        end
    end
    if set -q GSA_LANES; and test -n "$GSA_LANES"
        set -g _DEFAULT_LANES "$GSA_LANES"
    end
    if set -q GSA_JOBS; and test -n "$GSA_JOBS"
        set -g _DEFAULT_JOBS "$GSA_JOBS"
    end
    if set -q GSA_INTENSITY; and test -n "$GSA_INTENSITY"
        set -g _DEFAULT_INTENSITY "$GSA_INTENSITY"
    end
end

# Read config/topology.conf — the ONE topology source. One record per package:
#   id|path|groups|edges[|tags]
# (a lone id|path|groups| is a deliberate no-edge record; records ALWAYS exist
# for every package). Every validation path below names its offending record
# or field: the caller can only say "project configuration is invalid", so a
# bare return 1 leaves the user bisecting by hand (2026-09-20 rule).
function read_topology_config
    set -g _PACKAGE_MAP
    set -g _PACKAGE_IDS
    set -g _DEPS
    set -g _CONSUMER_INDEX
    set -g _TAGS
    for group_name in $_GROUP_NAMES
        assign_group "$group_name"
    end
    # Edge targets may name records further down the file, so edge validation
    # is deferred until every id is known; these hold id:dep,... meanwhile.
    set -l raw_edges
    set -l line_no 0
    for raw_line in (cat "$TOPOLOGY_FILE")
        set line_no (math $line_no + 1)
        set -l line (string trim -- "$raw_line")
        test -n "$line"; or continue
        string match -q '#*' -- "$line"; and continue
        set -l fields (string split '|' -- "$line")
        # Four fields (no tags) or five (tags present) — anything else is a
        # malformed record, not a historical shape.
        if test (count $fields) -lt 4; or test (count $fields) -gt 5
            ui_error "invalid topology record (expected 'id|path|groups|edges[|tags]'): $line"
            return 1
        end
        set -l id "$fields[1]"
        set -l relative_path "$fields[2]"
        if not string match -qr '^[A-Za-z0-9._+-]+$' -- "$id"
            ui_error "invalid topology record id '$id' (allowed: A-Za-z0-9._+-): $line"
            return 1
        end
        if contains "$id" $_PACKAGE_IDS
            ui_error "duplicate package id in topology record: $id ($TOPOLOGY_FILE line $line_no)"
            return 1
        end
        if string match -q '/*' -- "$relative_path"; \
                or string match -q '*..*' -- "$relative_path"; \
                or not test -f "$SCRIPT_DIR/$relative_path/PKGBUILD"
            ui_error "invalid topology record path for $id: $line"
            return 1
        end
        # groups: at least one member of the closed roster, no repeats.
        set -l record_groups
        for grp in (string split ',' -- "$fields[3]")
            test -n "$grp"; or continue
            if not contains "$grp" $_GROUP_NAMES
                ui_error "unknown group in topology record $id: $grp (allowed: "(string join ',' $_GROUP_NAMES)")"
                return 1
            end
            if contains "$grp" $record_groups
                ui_error "$grp appears twice in the groups field of topology record $id"
                return 1
            end
            set -a record_groups "$grp"
        end
        if test (count $record_groups) -eq 0
            ui_error "topology record for $id names no group (allowed: "(string join ',' $_GROUP_NAMES)")"
            return 1
        end
        # edges: empty is valid and deliberate; repeats are drift.
        set -l record_edges
        for dep in (string split ',' -- "$fields[4]")
            test -n "$dep"; or continue
            if contains "$dep" $record_edges
                ui_error "$dep appears twice in the edges field of topology record $id"
                return 1
            end
            set -a record_edges "$dep"
        end
        # tags: closed vocabulary, no repeats. Unknown tags are refused, not
        # ignored — a typo'd batch tag would silently disable the batch gate.
        # Vocabulary: abi=must, abi=should (batch relation),
        # app-cluster=<name> (the app prompt's shared toggle row), and
        # version-sync=nvchecker (explicit version-source opt-in). Like the
        # abi tags, app-cluster and version-sync are accepted on ANY group's
        # record — the loader validates tags by their own semantics, never by
        # group membership; outside their owning seam they are inert.
        set -l record_tags
        if test (count $fields) -eq 5
            for tag in (string split ',' -- "$fields[5]")
                test -n "$tag"; or continue
                if not contains "$tag" abi=must abi=should version-sync=nvchecker; and not string match -qr '^app-cluster=[A-Za-z0-9._+-]+$' -- "$tag"
                    ui_error "unknown tag in topology record $id: $tag (allowed: abi=must,abi=should,app-cluster=<name>,version-sync=nvchecker)"
                    return 1
                end
                if contains "$tag" $record_tags
                    ui_error "$tag appears twice in the tags field of topology record $id"
                    return 1
                end
                set -a record_tags "$tag"
            end
            if contains abi=must $record_tags; and contains abi=should $record_tags
                ui_error "topology record for $id names both abi=must and abi=should"
                return 1
            end
            set -l cluster_tag_count 0
            for tag in $record_tags
                string match -q 'app-cluster=*' -- "$tag"
                and set cluster_tag_count (math $cluster_tag_count + 1)
            end
            if test $cluster_tag_count -gt 1
                ui_error "topology record for $id names more than one app-cluster tag"
                return 1
            end
        end
        set -a _PACKAGE_IDS "$id"
        set -a _PACKAGE_MAP "$id|$relative_path"
        set -a raw_edges (printf '%s:%s' "$id" (string join ',' $record_edges))
        for grp in $record_groups
            set -l mangled (string replace - _ -- "$grp")
            set -a "_GROUP_$mangled" "$id"
        end
        if test (count $record_tags) -gt 0
            set -a _TAGS (printf '%s|%s' "$id" (string join ',' $record_tags))
        end
    end

    # Now every id is known: validate edge targets and publish _DEPS in the
    # id:dep,... shape topo_sort/deps_of split on. The same pass publishes the
    # reverse adjacency _CONSUMER_INDEX (target|consumer pairs, the
    # _pkgname_index shape): selection expansion walks CONSUMERS — the set at
    # ABI risk when a package rebuilds — and that walk needs "who consumes
    # this" lookup on every node, which scanning _DEPS forward cannot answer.
    for entry in $raw_edges
        set -l parts (string split -m 1 ':' -- "$entry")
        set -l pkg "$parts[1]"
        set -l record_edges
        for dep in (string split ',' -- "$parts[2]")
            test -n "$dep"; or continue
            if not contains "$dep" $_PACKAGE_IDS
                ui_error "topology record for $pkg names an unknown dependency: $dep"
                return 1
            end
            set -a record_edges "$dep"
            set -a _CONSUMER_INDEX "$dep|$pkg"
        end
        set -a _DEPS (printf '%s:%s' "$pkg" (string join ',' $record_edges))
    end
    return 0
end

function load_project_config
    # Every return 1 below names its offender. The caller can only say
    # "project configuration is invalid", so a bare return 1 leaves the user
    # bisecting their config by hand (2026-09-20 audit).
    test -f "$TOPOLOGY_FILE"; or begin
        ui_error "topology not found: $TOPOLOGY_FILE"
        return 1
    end
    test -f "$DEFAULT_CONFIG_FILE"; or begin
        ui_error "build defaults not found: $DEFAULT_CONFIG_FILE"
        return 1
    end
    if not read_config_defaults
        ui_error "invalid build defaults: $DEFAULT_CONFIG_FILE"
        return 1
    end
    # Name the key the user wrote in build-defaults.conf, not the internal
    # variable that happens to hold it: they grep their config for the former.
    for pair in _MEMORY_PER_JOB_GIB=memory_per_job_gib \
        _CORE_MEMORY_PER_JOB_GIB=core_memory_per_job_gib \
        _RESERVED_MEMORY_GIB=reserved_memory_gib
        set -l parts (string split -m 1 '=' -- $pair)
        set -l var_name $parts[1]
        set -l value $$var_name
        if not string match -qr '^[1-9][0-9]*$' -- "$value"
            ui_error "invalid numeric build default: $parts[2]=$value"
            return 1
        end
    end
    for pair in _DEFAULT_LANES=lanes _DEFAULT_JOBS=jobs
        set -l parts (string split -m 1 '=' -- $pair)
        set -l var_name $parts[1]
        set -l value $$var_name
        if test "$value" != auto; and not string match -qr '^[1-9][0-9]*$' -- "$value"
            ui_error "invalid parallelism default: $parts[2]=$value"
            return 1
        end
    end
    if not intensity_is_valid "$_DEFAULT_INTENSITY"
        ui_error "invalid intensity default: $_DEFAULT_INTENSITY"
        return 1
    end

    # One record per package: id, path, groups, edges and tags validate
    # together (read_topology_config names every offender). The cross-file
    # agreement the four-file split needed is now inherent: every package
    # carries its groups and edges in its own record, so a package cannot be
    # mapped-but-ungrouped or edge-only.
    if not read_topology_config
        return 1
    end
    topo_sort (string join ' ' $_PACKAGE_IDS) >/dev/null
    if test (count $_TOPO_BLOCKED) -gt 0
        ui_error "dependency configuration did not produce a complete order"
        return 1
    end
    return 0
end

# ─── Topological sort (Kahn's algorithm) ─────────────────────────────────────
function topo_sort -a pkgs_str
    # pkgs_str is a space-separated list of package IDs.
    set -l pkgs (string split ' ' $pkgs_str)
    # Drop empty tokens: splitting an empty string yields one empty element,
    # which would otherwise be "sorted" as a package and then reported as a
    # blocked/cyclic member (an empty -g app selection did exactly that).
    set -l pkgs_filtered
    for p in $pkgs
        test -n "$p"; and set -a pkgs_filtered $p
    end
    set pkgs $pkgs_filtered
    set -g _TOPO_BLOCKED

    # Build dependency map: $dep_of[pkg] = "dep1 dep2 ..."
    set -l dep_of_pkg
    set -l all_deps
    for entry in $_DEPS
        set -l parts (string split ':' $entry)
        set -l pkg $parts[1]
        if test (count $parts) -ge 2 -a -n "$parts[2]"
            set -a dep_of_pkg "$pkg:"(string join ' ' (string split ',' $parts[2]))
        else
            set -a dep_of_pkg "$pkg:"
        end
    end

    # Kahn's algorithm
    # in_degree[pkg] = count of unprocessed deps that are in our build list
    set -l in_degree
    set -l queue
    set -l sorted

    # Initialize in-degrees
    for pkg in $pkgs
        set -l deps ""
        for entry in $dep_of_pkg
            set -l parts (string split ':' $entry -m 2)
            if test "$parts[1]" = "$pkg" -a -n "$parts[2]"
                set deps (string split ' ' $parts[2])
                break
            end
        end

        set -l deg 0
        for dep in $deps
            # Only count deps that are in our build list
            for p in $pkgs
                if test "$p" = "$dep"
                    set deg (math $deg + 1)
                    break
                end
            end
        end
        set -a in_degree "$pkg:$deg"

        if test $deg -eq 0
            set -a queue $pkg
        end
    end

    # Process queue
    while test (count $queue) -gt 0
        set -l pkg $queue[1]
        set -e queue[1]
        set -a sorted $pkg

        # Find packages that depend on this one
        for entry in $dep_of_pkg
            set -l parts (string split ':' $entry -m 2)
            if test (count $parts) -lt 2 -o -z "$parts[2]"
                continue
            end
            set -l deps (string split ' ' $parts[2])

            # Check if this pkg is a dep of the entry
            set -l is_dep 0
            for dep in $deps
                if test "$dep" = "$pkg"
                    set is_dep 1
                    break
                end
            end

            if test $is_dep -eq 1
                # Decrease in-degree
                set -l child $parts[1]
                for j in (seq (count $in_degree))
                    set -l iparts (string split ':' $in_degree[$j] -m 2)
                    if test "$iparts[1]" = "$child"
                        set -l new_deg (math $iparts[2] - 1)
                        set in_degree[$j] "$child:$new_deg"
                        if test $new_deg -eq 0
                            set -a queue $child
                        end
                        break
                    end
                end
            end
        end
    end

    # Append any remaining (cycles or missing deps) at the end
    for pkg in $pkgs
        set -l found 0
        for s in $sorted
            if test "$s" = "$pkg"
                set found 1
                break
            end
        end
        if test $found -eq 0
            set -a _TOPO_BLOCKED $pkg
            set -a sorted $pkg
        end
    end

    # Same empty-input trap as above: printf with no arguments still runs the
    # format once, so an empty result would print a newline and re-inject the
    # phantom member at the output seam.
    if test (count $sorted) -gt 0
        printf '%s\n' $sorted
    end
    test (count $_TOPO_BLOCKED) -eq 0
end

# ─── Expand to consumers ─────────────────────────────────────────────────────
# A selection expands DOWNSTREAM, never upstream: the seed plus every package
# that transitively consumes it over topology edges — exactly the set left at
# ABI risk when the seed rebuilds. What a package consumes is deliberately NOT
# pulled in: those inputs must already be current in the system (that is the
# --no-deps contract extended to every run), or a rebuild would quietly hide
# stale inputs behind a full-chain build.
function expand_consumers
    set -l result
    set -l queue $argv

    while test (count $queue) -gt 0
        set -l pkg $queue[1]
        set -e queue[1]

        # Skip if already in result
        set -l already_seen 0
        for r in $result
            if test "$r" = "$pkg"
                set already_seen 1
                break
            end
        end
        if test $already_seen -eq 1
            continue
        end

        set -a result $pkg

        # Every record that lists $pkg among its edges consumes it: pull the
        # consumer side of each reverse-adjacency pair (built once by
        # read_topology_config).
        for entry in $_CONSUMER_INDEX
            set -l parts (string split '|' -- "$entry")
            if test "$parts[1]" = "$pkg"
                set -l consumer "$parts[2]"
                if package_path "$consumer" >/dev/null
                    set -a queue $consumer
                else
                    ui_error "missing local dependency: $consumer -> $pkg" >&2
                    return 1
                end
            end
        end
    end

    # Same empty-input trap as topo_sort: printf with no arguments still runs
    # the format once, so an empty closure must print nothing — not a phantom
    # empty member.
    if test (count $result) -gt 0
        printf '%s\n' $result
    end
end

# _DEFER_WAITER_CAP — how many packages may wait on one parked recipe before
# the wait costs more than a build attempt ("few packages definitely could
# wait", owner 2026-10-02). Above it, or when the consumer closure cannot be
# resolved, unverifiable freshness falls back to a normal build attempt.
set -g _DEFER_WAITER_CAP 3

# unverifiable_defer_plan PKG_ID → prints `defer` or `build`: may this recipe
# park on an unverifiable upstream, or must we try a normal build? Park only
# when the consumer chain can absorb the wait: nothing consumes the package,
# or at most _DEFER_WAITER_CAP transitive consumers (the dispatcher honestly
# parks those as waits-on-deferred). This keeps one parked recipe from
# silently breaking the packages that consume it.
function unverifiable_defer_plan -a pkg
    if test (count $_CONSUMER_INDEX) -eq 0
        if not read_topology_config
            # No topology, no honest parking plan.
            echo build
            return 0
        end
    end
    set -l closure (expand_consumers $pkg)
    if test $status -ne 0
        # Unresolvable consumer chain: fall back to building.
        echo build
        return 0
    end
    set -l waiters (math (count $closure) - 1)
    if test $waiters -le $_DEFER_WAITER_CAP
        echo defer
    else
        echo build
    end
end

# Read PKGBUILD scalars through Bash like arrays; values may depend on earlier
# shell assignments.
function pkgbuild_var -a pkg_path var
    bash -c '
        [[ $2 =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || exit 2
        __gsa_pkgbuild_var_name=$2
        readonly __gsa_pkgbuild_var_name
        cd "$1" || exit 1
        source ./PKGBUILD >/dev/null 2>&1 || exit $?
        declare -p "$__gsa_pkgbuild_var_name" >/dev/null 2>&1 || exit 0
        printf "%s\n" "${!__gsa_pkgbuild_var_name}"
    ' _ "$pkg_path" "$var" 2>/dev/null
end

# Read the archive-selection version pair once; makepkg writes pkgver()'s
# resolved value back to PKGBUILD, which keeps discovery aligned with its archive.
function pkgbuild_version -a pkg_path
    bash -c '
        cd "$1" || exit 1
        source ./PKGBUILD >/dev/null 2>&1 || exit $?
        printf "pkgver=%s\npkgrel=%s\n" "${pkgver-}" "${pkgrel-}"
    ' _ "$pkg_path" 2>/dev/null
end

# Print an *expanded* PKGBUILD array, one element per line. Sourcing is the only
# way to get what makepkg sees: `source=(…tar.gz{,.sig})` is two entries and
# `{,-doc}` is two more, and a $pkgver inside an entry is a version. Tokenising
# the text instead gets both wrong — a mistake this audit made twice before
# catching it, and one that would silently miscalculate checksum coverage.
function pkgbuild_array -a pkg_path name
    bash -c 'source "$1" >/dev/null 2>&1; eval "printf \"%s\n\" \"\${$2[@]}\""' _ "$pkg_path/PKGBUILD" "$name" 2>/dev/null
end

function pkgbuild_base -a pkg_path
    set -l pkgbase (pkgbuild_var "$pkg_path" pkgbase)
    if test -z "$pkgbase"
        set -l names (pkgbuild_array "$pkg_path" pkgname)
        set -l names_status $status
        if test $names_status -eq 0; and test (count $names) -eq 1
            set pkgbase "$names[1]"
        end
    end
    if test -z "$pkgbase"
        set pkgbase (basename "$pkg_path")
    end
    echo "$pkgbase"
end

# ─── Sync stable package version with Arch repos ─────────────────────────────
# Return contract (build_package switches on it):
#   0 = nothing to do — not a stable recipe, already current, or the repo
#       version/pkgrel is a downgrade
#   1 = rewritten, and pkgver moved
#   2 = rewrite failed
#   3 = rewritten, but only pkgrel/epoch moved
#
# 1 and 3 are informational only: whether the committed sums went stale depends
# on whether a source=() entry actually changed, which build_package determines
# by diffing the expanded array around this call. See the comment there.
function sync_stable_version -a pkg_path
    # Only applies to recipes physically staged under packages/stable.
    string match -q "$SCRIPT_DIR/packages/stable/*" "$pkg_path"; or return 0

    # pkgver()-driven PKGBUILDs (Qt dev-branch builds) have NO stable pkgver=
    # line — inserting one would OVERRIDE pkgver() and pin the version to the
    # repo release, defeating dev tracking. Skip them; their describe-based
    # version is always ahead of the repo anyway (never-downgrade guard).
    if not grep -q '^pkgver=' "$pkg_path/PKGBUILD"
        return 0
    end

    set -l pkgbase (pkgbuild_var "$pkg_path" pkgbase)
    if test -z "$pkgbase"
        set pkgbase (basename "$pkg_path")
    end

    # Candidate names to query: pkgbase first, then every split package name
    # (resolved in bash so comments/variables in pkgname=() don't break it).
    # E.g. hip-runtime's PKGBUILD builds pkgname=(hip-runtime-amd) — the repo
    # only knows the latter, so a pkgbase-only query would silently NEVER sync
    # and -Syu would replace the custom build with the newer stock one.
    set -l candidates "$pkgbase"
    for n in (bash -c "source '$pkg_path/PKGBUILD' 2>/dev/null && printf '%s\n' \"\${pkgname[@]}\"" 2>/dev/null)
        set -a candidates "$n"
    end

    # Query latest version from Arch repos
    set -l repo_info ""
    for c in $candidates
        set repo_info (pacman -Si "$c" 2>/dev/null)
        if test -n "$repo_info"
            break
        end
    end
    if test -z "$repo_info"
        return 0
    end

    set -l repo_ver_full (printf '%s\n' $repo_info | grep -m1 '^Version' | awk '{print $NF}')
    if test -z "$repo_ver_full"
        return 0
    end

    # Split "2.42.2-1", "7.2.4-1.1", or "1:7.1-1" (epoch) into epoch/version/release
    set -l repo_epoch 0
    set -l repo_v $repo_ver_full
    if string match -qr '^[0-9]+:' "$repo_v"
        set repo_epoch (string replace -r -- ':.*$' '' "$repo_v")
        set repo_v (string replace -r -- '^[0-9]+:' '' "$repo_v")
    end
    set -l repo_pkgver (string replace -r -- '-[0-9].*$' '' "$repo_v")
    set -l repo_pkgrel (string match -r -- '-([0-9].*)$' "$repo_v")[2]
    if test -z "$repo_pkgrel"
        set repo_pkgrel 1
    end

    # Read current version
    set -l cur_pkgver (pkgbuild_var "$pkg_path" pkgver)
    set -l cur_pkgrel (pkgbuild_var "$pkg_path" pkgrel)

    # Never downgrade the content version — repos can game vercmp with an epoch
    # (e.g. repo "1:7.1-1" vs local "7.2-1": 7.2 content is newer, keep it)
    set -l vercmp_res -1
    if type -q vercmp
        set vercmp_res (vercmp "$cur_pkgver" "$repo_pkgver")
    else if test "$cur_pkgver" = "$repo_pkgver"
        set vercmp_res 0
    end
    if test "$vercmp_res" -gt 0
        return 0
    end
    if test "$vercmp_res" -eq 0
        if test "$cur_pkgrel" = "$repo_pkgrel"
            return 0
        end
        # pkgver is at repo parity, so only a repo pkgrel that is actually
        # AHEAD is a sync worth making. A local pkgrel ahead of the repo is a
        # deliberate bump (e.g. ripgrep's Rust PGO wave carries pkgrel 2 over
        # the repo's 1), not staleness — rewriting it back to the repo value
        # clobbered ripgrep 15.2.0-2 to 15.2.0-1 on 2026-09-28, silently
        # re-stamping a PGO build with the pre-PGO revision identity. Same as
        # the pkgver guard above, the ordering rests on vercmp; without it the
        # inequality case falls through to the historical rewrite behaviour.
        set -l pkgrel_cmp 0
        if type -q vercmp
            set pkgrel_cmp (vercmp "$cur_pkgrel" "$repo_pkgrel")
        end
        if test "$pkgrel_cmp" -ge 0
            return 0
        end
    end

    if test "$_BUILD_QUIET" != "1"
        ui_info "$pkgbase: $cur_pkgver-$cur_pkgrel → $repo_pkgver-$repo_pkgrel (synced with repo)"
    end

    # Whether the *sources* move. A repo bump that carries only pkgrel or epoch
    # leaves source=() alone, so the committed sums still verify and the caller
    # must not treat the recipe as stale. Compared before the rewrite, because
    # the rewrite is what destroys the old value.
    set -l pkgver_changed 0
    if test "$cur_pkgver" != "$repo_pkgver"
        set pkgver_changed 1
    end

    # Update pkgver/pkgrel (+ epoch when the repo carries one — never inside pkgver,
    # makepkg rejects colons there)
    if not sed -i "s/^pkgver=.*/pkgver=$repo_pkgver/" "$pkg_path/PKGBUILD"
        return 2
    end
    if not sed -i "s/^pkgrel=.*/pkgrel=$repo_pkgrel/" "$pkg_path/PKGBUILD"
        return 2
    end
    if grep -q '^epoch=' "$pkg_path/PKGBUILD"
        if not sed -i "s/^epoch=.*/epoch=$repo_epoch/" "$pkg_path/PKGBUILD"
            return 2
        end
    else if test "$repo_epoch" -ne 0
        if not sed -i "/^pkgrel=.*/a epoch=$repo_epoch" "$pkg_path/PKGBUILD"
            return 2
        end
    end

    # Clean stale source/build artifacts
    if not command rm -rf -- "$pkg_path/src" "$pkg_path/pkg" "$pkg_path/build"
        return 2
    end

    # Run-level witness: a run never commits (the disposition of these edits is
    # the owner's), so the end-of-run summary must name every recipe this run
    # rewrote — best-effort append; the per-package log keeps the record
    # either way.
    printf '%s: %s → %s (synced with repo)\n' \
        "$pkgbase" "$cur_pkgver-$cur_pkgrel" "$repo_pkgver-$repo_pkgrel" \
        >>"$_STATE_DIR/synced.list" 2>/dev/null

    if test $pkgver_changed -eq 1
        return 1
    end
    return 3
end

function remove_version_sync_temp -a tmp
    if test -n "$tmp"; and test -d "$tmp"
        command rm -rf -- "$tmp"
    end
end

function restore_version_sync_recipe -a pkg_path original tmp
    set -l restore_status 0
    if not cp -p -- "$original" "$pkg_path/PKGBUILD"
        ui_error "$(basename "$pkg_path"): could not restore $pkg_path/PKGBUILD after version sync"
        set restore_status 1
    end
    remove_version_sync_temp "$tmp"
    return $restore_status
end

function sync_nvchecker_version -a package_id pkg_path
    set -l pkg_name "$package_id"
    set -l pkgbase (pkgbuild_base "$pkg_path")
    set -l config "$pkg_path/.nvchecker.toml"
    set -l resolver "$SCRIPT_DIR/tools/nvcheck.sh"
    if not test -f "$config"; or not test -f "$resolver"
        ui_error "$pkg_name: the opted-in nvchecker config or resolver is missing"
        return $lane_outcome_defer
    end

    set -l repository_root (cd "$SCRIPT_DIR" 2>/dev/null && pwd -P)
    set -l tmp_base /tmp
    if set -q TMPDIR; and test -n "$TMPDIR"
        set tmp_base "$TMPDIR"
    end
    set tmp_base (cd -- "$tmp_base" 2>/dev/null && pwd -P)
    if test -z "$repository_root"; or test -z "$tmp_base"
        ui_error "$pkg_name: cannot resolve a safe version-sync temporary directory"
        return $lane_outcome_defer
    end
    if test "$tmp_base" = "$repository_root"; or string match -q "$repository_root/*" -- "$tmp_base"
        ui_error "$pkg_name: TMPDIR must be outside the repository for version sync"
        return $lane_outcome_defer
    end
    set -l tmp (mktemp -d "$tmp_base/gsa-version-sync.XXXXXXXX" 2>/dev/null)
    if test $status -ne 0; or test -z "$tmp"
        ui_error "$pkg_name: cannot create isolated version-sync state"
        return $lane_outcome_defer
    end
    set -l tmp_created "$tmp"
    set tmp (cd "$tmp" 2>/dev/null && pwd -P)
    if test -z "$tmp"
        ui_error "$pkg_name: cannot resolve isolated version-sync state"
        remove_version_sync_temp "$tmp_created"
        return $lane_outcome_defer
    end
    set -l original "$tmp/PKGBUILD.original"
    if not cp -p -- "$pkg_path/PKGBUILD" "$original"
        ui_error "$pkg_name: cannot snapshot PKGBUILD before version sync"
        remove_version_sync_temp "$tmp"
        return 2
    end

    set -l provider_info (bash "$resolver" --provider "$config" "$pkgbase" 2>"$tmp/provider.err")
    set -l provider_status $status
    if test $provider_status -ne 0; or test (count $provider_info) -ne 2
        ui_error "$pkg_name: cannot read its nvchecker provider metadata"
        if test -s "$tmp/provider.err"
            sed 's/^/  /' "$tmp/provider.err"
        end
        remove_version_sync_temp "$tmp"
        return $lane_outcome_defer
    end
    set -l provider "$provider_info[1]"
    set -l provider_id "$provider_info[2]"

    set -l new_pkgver (env TMPDIR="$tmp" bash "$resolver" --resolve "$config" "$pkgbase" 2>"$tmp/resolve.err")
    set -l resolve_status $status
    if test $resolve_status -ne 0; or test (count $new_pkgver) -ne 1
        ui_error "$pkg_name: nvchecker could not resolve a version from $provider_id"
        if test -s "$tmp/resolve.err"
            sed 's/^/  /' "$tmp/resolve.err"
        end
        remove_version_sync_temp "$tmp"
        return $lane_outcome_defer
    end
    if not string match -qr '^[A-Za-z0-9._+]+$' -- "$new_pkgver"
        ui_error "$pkg_name: refusing unsupported upstream pkgver format '$new_pkgver'"
        remove_version_sync_temp "$tmp"
        return 4
    end

    set -l aur_srcinfo ""
    set -l aur_pkgrel ""
    set -l aur_epoch 0
    if test "$provider" = aur
        if not type -q curl
            ui_error "$pkg_name: cannot read AUR metadata because curl is missing"
            remove_version_sync_temp "$tmp"
            return $lane_outcome_defer
        end
        set aur_srcinfo "$tmp/aur.SRCINFO"
        if not curl -fsSL --max-time 60 --connect-timeout 10 -o "$aur_srcinfo" \
            "https://aur.archlinux.org/cgit/aur.git/plain/.SRCINFO?h=$provider_id" \
            2>"$tmp/aur-curl.err"
            ui_error "$pkg_name: AUR .SRCINFO for $provider_id is unavailable"
            if test -s "$tmp/aur-curl.err"
                sed 's/^/  /' "$tmp/aur-curl.err"
            end
            remove_version_sync_temp "$tmp"
            return $lane_outcome_defer
        end
        set -l aur_pkgbase (srcinfo_pkgbase "$aur_srcinfo")
        set -l aur_pkgver (srcinfo_pkgver "$aur_srcinfo")
        if test "$aur_pkgbase" != "$provider_id"; or test "$aur_pkgbase" != "$pkgbase"; or test "$aur_pkgver" != "$new_pkgver"
            ui_error "$pkg_name: AUR .SRCINFO changed or disagrees with nvchecker (expected $provider_id $new_pkgver, got $aur_pkgbase $aur_pkgver)"
            remove_version_sync_temp "$tmp"
            return $lane_outcome_defer
        end
        set aur_pkgrel (srcinfo_pkgrel "$aur_srcinfo")
        set -l aur_pkgrel_status $status
        set aur_epoch (srcinfo_epoch "$aur_srcinfo")
        if test $aur_pkgrel_status -ne 0; or not string match -qr '^[A-Za-z0-9._+]+$' -- "$aur_pkgrel"; or not string match -qr '^[0-9]+$' -- "$aur_epoch"
            ui_error "$pkg_name: AUR .SRCINFO has an invalid pkgrel or epoch"
            remove_version_sync_temp "$tmp"
            return $lane_outcome_defer
        end
    end

    set -l cur_pkgver (pkgbuild_var "$pkg_path" pkgver)
    set -l cur_pkgrel (pkgbuild_var "$pkg_path" pkgrel)
    set -l cur_epoch (pkgbuild_var "$pkg_path" epoch)
    if test -z "$cur_pkgrel"
        set cur_pkgrel 1
    end
    if test -z "$cur_epoch"
        set cur_epoch 0
    end
    if test -z "$cur_pkgver"; or not string match -qr '^[A-Za-z0-9._+]+$' -- "$cur_pkgver"; or not string match -qr '^[A-Za-z0-9._+]+$' -- "$cur_pkgrel"; or not string match -qr '^[0-9]+$' -- "$cur_epoch"
        ui_error "$pkg_name: the current PKGBUILD version metadata is invalid"
        remove_version_sync_temp "$tmp"
        return 4
    end
    if not type -q vercmp
        ui_error "$pkg_name: cannot compare versions because vercmp is missing"
        remove_version_sync_temp "$tmp"
        return $lane_outcome_defer
    end
    set -l version_order (vercmp "$cur_pkgver" "$new_pkgver")
    if test $status -ne 0
        ui_error "$pkg_name: vercmp could not compare $cur_pkgver and $new_pkgver"
        remove_version_sync_temp "$tmp"
        return $lane_outcome_defer
    end
    if test $version_order -gt 0
        remove_version_sync_temp "$tmp"
        return 0
    end

    set -l new_pkgrel "$cur_pkgrel"
    set -l new_epoch "$cur_epoch"
    if test "$provider" = aur
        if test $version_order -lt 0
            set new_pkgrel "$aur_pkgrel"
            set new_epoch "$aur_epoch"
        else
            set -l release_order (vercmp "$cur_pkgrel" "$aur_pkgrel")
            if test $release_order -lt 0
                set new_pkgrel "$aur_pkgrel"
            end
            if test "$aur_epoch" -gt "$cur_epoch"
                set new_epoch "$aur_epoch"
            end
        end
    else if test "$provider" = github; and test $version_order -lt 0
        set new_pkgrel 1
    end

    if not test -f "$pkg_path/PKGBUILD"; or not grep -q '^pkgver=' "$pkg_path/PKGBUILD"; or not grep -q '^pkgrel=' "$pkg_path/PKGBUILD"
        ui_error "$pkg_name: PKGBUILD must define literal pkgver and pkgrel fields for version sync"
        remove_version_sync_temp "$tmp"
        return 4
    end
    set -l pkgver_changed 0
    if test "$cur_pkgver" != "$new_pkgver"
        set pkgver_changed 1
    end
    set -l metadata_changed 0
    if test "$pkgver_changed" -eq 1; or test "$cur_pkgrel" != "$new_pkgrel"; or test "$cur_epoch" != "$new_epoch"
        set metadata_changed 1
    end
    set -l sources_before (pkgbuild_array "$pkg_path" source)
    if test $status -ne 0
        ui_error "$pkg_name: cannot evaluate the current PKGBUILD source array"
        remove_version_sync_temp "$tmp"
        return 4
    end

    if test "$metadata_changed" -eq 1
        if not sed -i "s/^pkgver=.*/pkgver=$new_pkgver/" "$pkg_path/PKGBUILD"
            ui_error "$pkg_name: could not update pkgver"
            restore_version_sync_recipe "$pkg_path" "$original" "$tmp"
            return 2
        end
        if not sed -i "s/^pkgrel=.*/pkgrel=$new_pkgrel/" "$pkg_path/PKGBUILD"
            ui_error "$pkg_name: could not update pkgrel"
            restore_version_sync_recipe "$pkg_path" "$original" "$tmp"
            return 2
        end
        if grep -q '^epoch=' "$pkg_path/PKGBUILD"
            if not sed -i "s/^epoch=.*/epoch=$new_epoch/" "$pkg_path/PKGBUILD"
                ui_error "$pkg_name: could not update epoch"
                restore_version_sync_recipe "$pkg_path" "$original" "$tmp"
                return 2
            end
        else if test "$new_epoch" -ne 0
            if not sed -i "/^pkgrel=.*/a epoch=$new_epoch" "$pkg_path/PKGBUILD"
                ui_error "$pkg_name: could not add epoch"
                restore_version_sync_recipe "$pkg_path" "$original" "$tmp"
                return 2
            end
        end
        if not command rm -rf -- "$pkg_path/src" "$pkg_path/pkg" "$pkg_path/build"
            ui_error "$pkg_name: could not clear artifacts after version sync"
            restore_version_sync_recipe "$pkg_path" "$original" "$tmp"
            return 2
        end
    end

    set -l sources_after (pkgbuild_array "$pkg_path" source)
    if test $status -ne 0
        ui_error "$pkg_name: resolved pkgver cannot be evaluated by its PKGBUILD; the recipe was restored"
        restore_version_sync_recipe "$pkg_path" "$original" "$tmp"
        return 4
    end
    if test "$provider" = aur; and not srcinfo_matches_sources "$aur_srcinfo" "$pkg_path"
        ui_error "$pkg_name: AUR .SRCINFO sources do not exactly match the rewritten recipe; the recipe was restored"
        restore_version_sync_recipe "$pkg_path" "$original" "$tmp"
        return $lane_outcome_defer
    end

    set -l moved_sources
    set -l source_count (count $sources_after)
    if test (count $sources_before) -gt $source_count
        set source_count (count $sources_before)
    end
    set -l source_index 1
    while test $source_index -le $source_count
        set -l before ""
        set -l after ""
        if test $source_index -le (count $sources_before)
            set before "$sources_before[$source_index]"
        end
        if test $source_index -le (count $sources_after)
            set after "$sources_after[$source_index]"
        end
        if test "$before" != "$after"; and test -n "$after"
            set -a moved_sources "$after"
        end
        set source_index (math $source_index + 1)
    end

    if test (count $moved_sources) -gt 0
        anchor_sums_from_provider "$pkg_path" "$provider" "$provider_id" "$aur_srcinfo" $moved_sources
        set -l anchor_status $status
        switch $anchor_status
            case 0
                # The checksum pipeline also refreshes a committed .SRCINFO.
            case 1
                refresh_package_srcinfo "$pkg_path" "version metadata was synced"
            case 4
                restore_version_sync_recipe "$pkg_path" "$original" "$tmp"
                return 4
            case 2 3
                restore_version_sync_recipe "$pkg_path" "$original" "$tmp"
                return $lane_outcome_defer
            case '*'
                ui_error "$pkg_name: unexpected checksum-anchor result $anchor_status"
                restore_version_sync_recipe "$pkg_path" "$original" "$tmp"
                return 2
        end
    else if test "$metadata_changed" -eq 1
        refresh_package_srcinfo "$pkg_path" "version metadata was synced"
    end

    if test "$metadata_changed" -eq 0
        remove_version_sync_temp "$tmp"
        return 0
    end
    set -l provider_label "$provider_id"
    if test "$provider" = aur
        set provider_label "AUR $provider_id"
    else
        set provider_label "GitHub $provider_id"
    end
    set -l old_version "$cur_pkgver-$cur_pkgrel"
    set -l new_version "$new_pkgver-$new_pkgrel"
    if test "$cur_epoch" -ne 0
        set old_version "$cur_epoch:$old_version"
    end
    if test "$new_epoch" -ne 0
        set new_version "$new_epoch:$new_version"
    end
    if test "$_BUILD_QUIET" != "1"
        ui_info "$pkgbase: $old_version → $new_version (synced with $provider_label)"
    end
    printf '%s: %s → %s (synced with %s)\n' \
        "$pkgbase" "$old_version" "$new_version" "$provider_label" \
        >>"$_STATE_DIR/synced.list" 2>/dev/null
    remove_version_sync_temp "$tmp"
    if test "$pkgver_changed" -eq 1
        return 1
    end
    return 3
end

# The URL part of a source entry, with any "name::" override removed, or nothing
# when the entry is an in-tree file (a patch, a dotfile, an .install script) that
# has no URL and so nothing to download.
function source_url -a entry
    set -l e $entry
    if string match -q '*::*' -- $e
        set e (string replace -r '^.*::' '' -- $e)
    end
    string match -q '*://*' -- $e; or return 1
    echo $e
end

# The VCS protocol of a source entry (git/svn/hg/bzr), or nothing for a plain
# download. It must be read from the URL part, after the "name::" prefix is
# removed: "fish::git+https://…" is a git checkout, and testing the raw entry
# misses it, so the checkout is then treated as a tarball and the build refused.
function source_vcs -a entry
    set -l e (source_url $entry); or return 1
    for p in git svn hg bzr
        if string match -q "$p+*" -- $e
            echo $p
            return 0
        end
    end
    return 1
end

# The name makepkg gives one source entry, which is what a checksum array
# describes: the "name::" override when the entry has one, otherwise the
# basename of the URL. Nothing is printed for a signature file (makepkg writes
# SKIP for those) or for an in-tree file, because neither is a download that a
# checksum published elsewhere can describe. The suffix list must cover every
# spelling of a detached signature — '.sign' is the kernel.org one
# (linux-7.2.7.tar.sign), and missing it is what made an official-SKIP entry
# look unanchorable and refused the recipe (measured 2026-09-24: makepkg
# verifies .sign with PGP against validpgpkeys — corrupting it fails the build
# with 'SIGNATURE NOT FOUND' — so its integrity is cryptographic, not a hash).
#
# The override matters: 'udisks2::git+…' downloads to "udisks2", and
# 'openshadinglanguage-…tar.gz::https://…/v1.15.3.0.tar.gz' downloads to
# "openshadinglanguage-…tar.gz", not to the URL's basename. Reading the basename
# instead made the verifier look for a file that does not exist, and — worse, for
# util-linux's renamed LICENSE — find a *different* file that happened to share
# it, which is a false mismatch in that case and a false *pass* in the other
# direction.
function source_filename -a entry
    set -l name ""
    if string match -q '*::*' -- $entry
        set name (string replace -r '::.*$' '' -- $entry)
    else
        set -l url (source_url $entry); or return 1
        set name (string replace -r '[?#].*$' '' -- $url)
        set name (string replace -r '^.*/' '' -- $name)
    end
    if test -z "$name"
        return 1
    end
    for suffix in .sig .asc .signature .sign
        string match -q "*$suffix" -- $name; and return 1
    end
    echo $name
end

# The protocol, URL, and selected ref from an expanded VCS source entry.
# Return one item per line so values containing spaces remain intact.
function vcs_source_ref_info -a entry
    set -l protocol (source_vcs "$entry"); or return 1
    set -l raw (source_url "$entry"); or return 1
    set raw (string replace -r '^(git|svn|hg|bzr)\+' '' -- "$raw")
    set -l parts (string split -m 1 '#' -- "$raw")
    set -l url "$parts[1]"
    set -l fragment ""
    if test (count $parts) -gt 1
        set fragment "$parts[2]"
    end
    set url (string replace -r '\?signed$' '' -- "$url")
    set fragment (string replace -r '\?signed$' '' -- "$fragment")

    set -l ref_kind default
    set -l ref_value -
    if test -n "$fragment"
        if string match -q '*=*' -- "$fragment"
            set ref_kind (string replace -r '=.*$' '' -- "$fragment")
            set ref_value (string replace -r '^[^=]*=' '' -- "$fragment")
        else
            set ref_kind revision
            set ref_value "$fragment"
        end
    end
    printf '%s\n' "$protocol" "$url" "$ref_kind" "$ref_value"
end

# Hash the expanded entry so revision records never expose credential-bearing URLs.
function vcs_source_key -a entry
    set -l key (printf '%s' "$entry" | sha256sum 2>/dev/null | cut -d ' ' -f1)
    string match -qr '^[0-9a-f]{64}$' -- "$key"; or return 1
    echo "$key"
end

# Locate the checkout makepkg actually compiled from. The authoritative root
# is $srcdir ($startdir/src/<name>): download_git keeps only the mirror in
# SRCDEST, extract_git clones the working copy into $srcdir, and
# build()/package() cd into it — so the src/ probe needs no environment at
# all, which matters because sudo's env_reset strips SRCDEST from the
# recorder's own environment in root-supervisor runs (2026-10-02 xdg-utils:
# 'missing local checkout' after a green build, the checkout one directory
# deeper in src/ the whole time). A mirror — in SRCDEST, or at the package
# root when SRCDEST defaults to $startdir — is a download cache whose HEAD is
# the remote's default branch, not the built ref (measured: mirror HEAD
# 03707c1f while the archive was compiled from 356c380a), so the package-root
# and SRCDEST roots are fallbacks only, tried when src/ has no working copy.
# Git strips .git from its default source name; honor both spellings in
# every root.
function vcs_source_checkout -a pkg_path entry
    set -l name (source_filename "$entry"); or return 1
    set -l names "$name"
    set -l stripped (string replace -r '\.git$' '' -- "$name")
    if test "$stripped" != "$name"
        set -a names "$stripped"
    end
    set -l roots "$pkg_path/src" "$pkg_path"
    if set -q SRCDEST; and test -n "$SRCDEST"
        set -a roots "$SRCDEST"
    end
    for root in $roots
        for candidate_name in $names
            set -l candidate "$root/$candidate_name"
            if test -d "$candidate"
                echo "$candidate"
                return 0
            end
        end
    end
    return 1
end

function vcs_local_revision -a protocol checkout
    switch "$protocol"
        case git
            env GIT_CONFIG_COUNT=0 git -c safe.bareRepository=all -C "$checkout" rev-parse --verify HEAD 2>/dev/null
        case svn
            command svn info --show-item revision "$checkout" 2>/dev/null
        case hg
            command hg --cwd "$checkout" log -r . --template '{node}' 2>/dev/null
        case bzr
            command bzr version-info --custom '--template={revision_id}' "$checkout" 2>/dev/null
        case '*'
            return 1
    end
end

# git_ls_remote [git-ls-remote args...] — one Git upstream query with a
# transport classifier and bounded retry. The exit status separates a
# COMPLETED query (0 = match, 2 = clean "no such ref" under --exit-code —
# never retried, an answer does not change on repetition) from a transport
# failure (anything else: TLS, timeout, dead host — no answer at all, the
# only retryable class; measured 2026-10-02: repo.or.cz answered 1 of 3
# attempts within a minute, so one shot is not an oracle for "upstream is
# gone"). 3 attempts, 0.5 s then 1 s backoff. Exhaustion returns the failing
# status with no rows; callers keep treating "no rows" as unresolvable.
# A persistent condition that LOOKS like transport (expired credentials,
# proxy 403) is retried and then fails the same way — the classifier only
# gates retries, never trust, so a misclassification costs latency, never a
# skip decision. Args are passed through verbatim so option order
# (--symref before the URL) stays the caller's.
function git_ls_remote_quiet
    set -l attempt 1
    while true
        set -l rows (env GIT_CONFIG_COUNT=0 GIT_TERMINAL_PROMPT=0 git \
            -c safe.bareRepository=all ls-remote $argv 2>/dev/null)
        set -l query_status $status
        if test $query_status -eq 0; or test $query_status -eq 2; or test $attempt -ge 4
            printf '%s\n' $rows
            return $query_status
        end
        # Flaky upstreams (repo.or.cz drops ~half of TLS handshakes from some
        # networks) need a window in seconds, not milliseconds (2026-10-02).
        switch $attempt
            case 1
                sleep 2
            case 2
                sleep 5
            case 3
                sleep 10
        end
        set attempt (math $attempt + 1)
    end
end

# Resolve the selected upstream ref, not an unrelated repository HEAD. Fixed
# Git commits and numeric SVN revisions are immutable inputs.
function vcs_remote_revision -a protocol url ref_kind ref_value
    switch "$protocol"
        case git
            switch "$ref_kind"
                case commit
                    string match -qr '^[0-9a-fA-F]{7,64}$' -- "$ref_value"; or return 1
                    echo (string lower -- "$ref_value")
                    return 0
                case branch
                    set -l target "$ref_value"
                    if not string match -q 'refs/heads/*' -- "$target"
                        set target "refs/heads/$target"
                    end
                    set -l rows (git_ls_remote_quiet --exit-code "$url" "$target")
                    for row in $rows
                        set -l fields (string split \t -- "$row")
                        if test (count $fields) -eq 2; and test "$fields[2]" = "$target"
                            string match -qr '^[0-9a-fA-F]{40,64}$' -- "$fields[1]"; or return 1
                            echo (string lower -- "$fields[1]")
                            return 0
                        end
                    end
                    return 1
                case tag
                    set -l target "$ref_value"
                    if not string match -q 'refs/tags/*' -- "$target"
                        set target "refs/tags/$target"
                    end
                    set -l peeled "$target^{}"
                    set -l rows (git_ls_remote_quiet --exit-code "$url" "$target" "$peeled")
                    set -l tag_revision ""
                    set -l peeled_revision ""
                    for row in $rows
                        set -l fields (string split \t -- "$row")
                        if test (count $fields) -eq 2
                            if test "$fields[2]" = "$target"
                                set tag_revision "$fields[1]"
                            else if test "$fields[2]" = "$peeled"
                                set peeled_revision "$fields[1]"
                            end
                        end
                    end
                    set -l revision "$peeled_revision"
                    if test -z "$revision"
                        set revision "$tag_revision"
                    end
                    string match -qr '^[0-9a-fA-F]{40,64}$' -- "$revision"; or return 1
                    echo (string lower -- "$revision")
                    return 0
                case default
                    set -l rows (git_ls_remote_quiet --symref --exit-code "$url" HEAD)
                    for row in $rows
                        set -l fields (string split \t -- "$row")
                        if test (count $fields) -eq 2; and test "$fields[2]" = HEAD
                            if string match -qr '^[0-9a-fA-F]{40,64}$' -- "$fields[1]"
                                echo (string lower -- "$fields[1]")
                                return 0
                            end
                        end
                    end
                    return 1
                case '*'
                    return 1
            end
        case svn
            if test "$ref_kind" != default; and test "$ref_kind" != revision
                return 1
            end
            if test "$ref_kind" = default
                set ref_value HEAD
            end
            if test "$ref_value" != HEAD; and string match -qr '^[0-9]+$' -- "$ref_value"
                echo "$ref_value"
                return 0
            end
            set -l revision (command svn --non-interactive info --show-item revision \
                --revision "$ref_value" "$url" 2>/dev/null)
            string match -qr '^[0-9]+$' -- "$revision"; or return 1
            echo "$revision"
            return 0
        case hg
            if test "$ref_kind" != default; and test "$ref_kind" != branch \
                and test "$ref_kind" != revision; and test "$ref_kind" != tag
                return 1
            end
            if test "$ref_kind" = default
                set ref_value default
            end
            set -l revision (command hg --config ui.interactive=False identify \
                --template '{node}' --rev "$ref_value" "$url" 2>/dev/null)
            string match -qr '^[0-9a-fA-F]{40,64}$' -- "$revision"; or return 1
            echo (string lower -- "$revision")
            return 0
        case bzr
            if test "$ref_kind" != default; and test "$ref_kind" != revision
                return 1
            end
            set -l args version-info --custom '--template={revision_id}'
            if test "$ref_kind" = revision
                set -a args "--revision=$ref_value"
            end
            set -a args "$url"
            set -l revision (command bzr $args 2>/dev/null)
            test -n "$revision"; or return 1
            echo "$revision"
            return 0
        case '*'
            return 1
    end
end

# Store one revision record for every distinct VCS source used by an archive.
# The sidecar is ignored by the existing *.pkg.tar.* rule and replaced atomically.
function record_vcs_archive_revisions -a pkg_path archive
    set -g _VCS_REVISION_ERROR ""
    set -l manifest "$archive.gsa-vcs-revisions"
    set -l entries
    set -l keys
    for entry in (pkgbuild_array "$pkg_path" source)
        set -l protocol (source_vcs "$entry")
        or continue
        set -l key (vcs_source_key "$entry")
        if test -z "$key"
            set -g _VCS_REVISION_ERROR "cannot identify a VCS source entry"
            return 1
        end
        if contains -- "$key" $keys
            continue
        end
        set -a keys "$key"
        set -a entries "$entry"
    end

    if test (count $entries) -eq 0
        if test -e "$manifest"; and not rm -f -- "$manifest"
            set -g _VCS_REVISION_ERROR "cannot remove stale VCS revision metadata"
            return 1
        end
        return 0
    end

    # The archive changed; invalidate any old record before collecting its new
    # revisions so a failed capture cannot make the replacement look current.
    if test -e "$manifest"; and not rm -f -- "$manifest"
        set -g _VCS_REVISION_ERROR "cannot replace VCS revision metadata"
        return 1
    end
    set -l temporary (mktemp "$manifest.tmp.XXXXXX" 2>/dev/null)
    if test -z "$temporary"
        set -g _VCS_REVISION_ERROR "cannot create VCS revision metadata"
        return 1
    end
    if not printf 'gsa-vcs-revisions\t1\n' >"$temporary"
        rm -f -- "$temporary"
        set -g _VCS_REVISION_ERROR "cannot write VCS revision metadata"
        return 1
    end

    for entry in $entries
        set -l info (vcs_source_ref_info "$entry")
        if test (count $info) -ne 4
            rm -f -- "$temporary"
            set -g _VCS_REVISION_ERROR "cannot parse a VCS source ref"
            return 1
        end
        set -l checkout (vcs_source_checkout "$pkg_path" "$entry")
        if test -z "$checkout"
            rm -f -- "$temporary"
            set -l name (source_filename "$entry")
            set -g _VCS_REVISION_ERROR "missing local checkout for $name"
            return 1
        end
        set -l revision (vcs_local_revision "$info[1]" "$checkout")
        if test -z "$revision"
            rm -f -- "$temporary"
            set -l name (source_filename "$entry")
            set -g _VCS_REVISION_ERROR "cannot read the built revision for $name"
            return 1
        end
        set -l key (vcs_source_key "$entry")
        if test -z "$key"; or not printf '%s\t%s\t%s\n' "$key" "$info[1]" "$revision" >>"$temporary"
            rm -f -- "$temporary"
            set -g _VCS_REVISION_ERROR "cannot write VCS revision metadata"
            return 1
        end
    end

    if not mv -f -- "$temporary" "$manifest"
        rm -f -- "$temporary"
        set -g _VCS_REVISION_ERROR "cannot publish VCS revision metadata"
        return 1
    end
    if test "$_ROOT_MODE" = "1"; and not chown "$_BUILD_USER": "$manifest"
        set -g _VCS_REVISION_ERROR "cannot restore VCS revision metadata ownership"
        return 1
    end
    return 0
end

# Confirm every selected source ref can be resolved before rebuilding an
# archive whose saved baseline is missing or unusable.
function vcs_selected_refs_queryable
    for entry in $argv
        set -l info (vcs_source_ref_info "$entry")
        if test (count $info) -ne 4
            set -g _VCS_REVISION_ERROR "cannot parse a VCS source ref"
            return 1
        end
        set -l current (vcs_remote_revision "$info[1]" "$info[2]" "$info[3]" "$info[4]")
        if test -z "$current"
            set -l name (source_filename "$entry")
            set -g _VCS_REVISION_ERROR "cannot query upstream revision for $name"
            return 1
        end
    end
    return 0
end

# Return 0 when a VCS archive is current, 1 when a selected ref moved, 2 when
# its current state cannot be established, and 3 when a rebuild can establish
# a missing or unusable baseline. Both -s callers defer (rc 99) on 2 — an
# unverifiable upstream must neither fail the run nor license a skip.
function vcs_archive_is_current -a pkg_path archive
    set -g _VCS_REVISION_ERROR ""
    set -l entries
    set -l keys
    for entry in (pkgbuild_array "$pkg_path" source)
        set -l protocol (source_vcs "$entry")
        or continue
        set -l key (vcs_source_key "$entry")
        if test -z "$key"
            set -g _VCS_REVISION_ERROR "cannot identify a VCS source entry"
            return 2
        end
        if contains -- "$key" $keys
            continue
        end
        set -a keys "$key"
        set -a entries "$entry"
    end
    if test (count $entries) -eq 0
        return 0
    end

    set -l manifest "$archive.gsa-vcs-revisions"
    if not test -f "$manifest"
        if not vcs_selected_refs_queryable $entries
            return 2
        end
        set -g _VCS_REVISION_ERROR "no recorded VCS baseline for "(basename "$archive")
        return 3
    end
    set -l manifest_count (awk -F '\t' '
        NR == 1 {
            if ($0 != "gsa-vcs-revisions\t1") bad = 1
            next
        }
        NF != 3 || length($1) != 64 || $1 !~ /^[0-9a-f]+$/ ||
            $2 !~ /^(git|svn|hg|bzr)$/ || $3 == "" { bad = 1; next }
        { count++ }
        END {
            if (bad) exit 1
            printf "%d\n", count + 0
        }
    ' "$manifest" 2>/dev/null)
    set -l expected_count (count $entries)
    if test -z "$manifest_count"; or test "$manifest_count" != "$expected_count"
        if not vcs_selected_refs_queryable $entries
            return 2
        end
        set -g _VCS_REVISION_ERROR "VCS baseline is missing, malformed, or belongs to different sources"
        return 3
    end

    for entry in $entries
        set -l info (vcs_source_ref_info "$entry")
        set -l key (vcs_source_key "$entry")
        if test (count $info) -ne 4; or test -z "$key"
            set -g _VCS_REVISION_ERROR "cannot parse a VCS source ref"
            return 2
        end
        set -l fields (awk -F '\t' -v key="$key" \
            '$1 == key { print $2; print $3 }' "$manifest" 2>/dev/null)
        if test (count $fields) -ne 2; or test "$fields[1]" != "$info[1]"
            if not vcs_selected_refs_queryable $entries
                return 2
            end
            set -l name (source_filename "$entry")
            set -g _VCS_REVISION_ERROR "VCS baseline does not match source $name"
            return 3
        end
        set -l current (vcs_remote_revision "$info[1]" "$info[2]" "$info[3]" "$info[4]")
        if test -z "$current"
            set -l name (source_filename "$entry")
            set -g _VCS_REVISION_ERROR "cannot query upstream revision for $name"
            return 2
        end
        if test "$info[1]" = git; and test "$info[3]" = commit
            if not string match -q "$current*" -- "$fields[2]"
                set -l name (source_filename "$entry")
                set -g _VCS_REVISION_ERROR "pinned Git commit does not match source $name"
                return 1
            end
        else if test "$fields[2]" != "$current"
            set -l name (source_filename "$entry")
            set -g _VCS_REVISION_ERROR "selected upstream ref moved for source $name"
            return 1
        end
    end
    return 0
end

# Snapshot archive path, nanosecond mtime, and size so records are written only
# for files makepkg actually replaced (including split outputs).
function package_archive_snapshot -a pkg_path
    find "$pkg_path" -maxdepth 1 -type f -name '*.pkg.tar.zst' \
        -printf '%p\t%T@\t%s\n' 2>/dev/null
end

# The pkgver a .SRCINFO declares for its pkgbase, or nothing when it has none.
function srcinfo_pkgver -a srcinfo
    for line in (cat "$srcinfo" 2>/dev/null)
        if string match -qr '^\s*pkgname\s*=' -- $line
            break
        end
        if string match -qr '^\s*pkgver\s*=' -- $line
            echo (string replace -r '^\s*pkgver\s*=\s*' '' -- $line)
            return 0
        end
    end
    return 1
end

function srcinfo_base_value -a srcinfo field
    for line in (cat "$srcinfo" 2>/dev/null)
        if string match -qr '^\s*pkgname\s*=' -- "$line"
            break
        end
        if string match -qr -- "^\s*$field\s*=" "$line"
            echo (string replace -r -- "^\s*$field\s*=\s*" '' "$line")
            return 0
        end
    end
    return 1
end

function srcinfo_pkgbase -a srcinfo
    srcinfo_base_value "$srcinfo" pkgbase
end

function srcinfo_pkgrel -a srcinfo
    srcinfo_base_value "$srcinfo" pkgrel
end

function srcinfo_epoch -a srcinfo
    set -l epoch (srcinfo_base_value "$srcinfo" epoch)
    if test -z "$epoch"
        echo 0
    else
        echo $epoch
    end
end

function srcinfo_base_sources -a srcinfo
    for line in (cat "$srcinfo" 2>/dev/null)
        if string match -qr '^\s*pkgname\s*=' -- "$line"
            break
        end
        if string match -qr '^\s*source\s*=' -- "$line"
            echo (string replace -r '^\s*source\s*=\s*' '' -- "$line")
        end
    end
end

function srcinfo_matches_sources -a srcinfo pkg_path
    set -l published_sources (srcinfo_base_sources "$srcinfo")
    set -l recipe_sources (pkgbuild_array "$pkg_path" source)
    set -l recipe_status $status
    if test $recipe_status -ne 0; or test (count $published_sources) -ne (count $recipe_sources)
        return 1
    end
    set -l i 1
    while test $i -le (count $recipe_sources)
        if test "$published_sources[$i]" != "$recipe_sources[$i]"
            return 1
        end
        set i (math $i + 1)
    end
    return 0
end

# Checksum map for one recipe as "<file>\t<algorithm>\t<value>", read from
# the *pkgbase* section of a .SRCINFO.
#
# makepkg writes .SRCINFO with every `source =` line in order, then each checksum
# array in order, and it is already brace-expanded — so it is both easier and
# safer to read than a provider PKGBUILD, which would have to be *executed* to
# be expanded. Sources and sums only line up *within* one algorithm, though:
# Arch and AUR publish the same file list once per algorithm (fish has one
# source with both a sha512 and a b2 sum), so the flat list is not aligned. Only
# the first contiguous run of one algorithm is used, and the function returns 1
# unless that run is exactly as long as the source list, so an unparseable file
# can never be anchored to.
function srcinfo_sum_map -a srcinfo
    set -l srcs
    set -l algos
    set -l vals
    for line in (cat "$srcinfo" 2>/dev/null)
        if string match -qr '^\s*pkgname\s*=' -- $line
            break
        end
        if string match -qr '^\s*source\s*=' -- $line
            set -a srcs (string replace -r '^\s*source\s*=\s*' '' -- $line)
        else if string match -qr '^\s*(sha256|sha512|b2|md5)sums\s*=' -- $line
            set -a algos (string replace -r 'sums$' '' -- (string replace -r '^\s*([a-z0-9]+)\s*=.*$' '$1' -- $line))
            set -a vals (string replace -r '^\s*[a-z0-9]+\s*=\s*' '' -- $line)
        end
    end
    if test (count $srcs) -eq 0; or test (count $algos) -lt (count $srcs)
        return 1
    end
    set -l alg $algos[1]
    set -l run 0
    for a in $algos
        if test "$a" != "$alg"
            break
        end
        set run (math $run + 1)
    end
    if test $run -ne (count $srcs)
        return 1
    end
    for i in (seq (count $srcs))
        if test -z "$vals[$i]"; or test "$vals[$i]" = "SKIP"
            continue
        end
        set -l f (source_filename $srcs[$i])
        if test -z "$f"
            continue
        end
        printf '%s\t%s\t%s\n' $f $alg $vals[$i]
    end
end

function github_release_checksum_map -a repo pkgver tmp map_file tag_file
    if not type -q python3
        ui_error "$repo: Python 3 is required to read GitHub release metadata"
        return 2
    end
    set -l found_release 0
    for tag in "$pkgver" "v$pkgver"
        set -l response "$tmp/github-release-$tag.json"
        set -l http_code (curl --silent --show-error --location \
            --max-time 60 --connect-timeout 10 --output "$response" \
            --write-out '%{http_code}' \
            "https://api.github.com/repos/$repo/releases/tags/$tag" \
            2>"$tmp/github-curl.err")
        set -l curl_status $status
        if test $curl_status -ne 0
            ui_error "$repo: GitHub release metadata request failed for tag $tag (curl exit $curl_status)"
            if test -s "$tmp/github-curl.err"
                tail -5 "$tmp/github-curl.err" | sed 's/^/  /'
            end
            return 2
        end
        if test "$http_code" = 404
            continue
        end
        if test "$http_code" != 200
            ui_error "$repo: GitHub release metadata for tag $tag returned HTTP $http_code"
            return 2
        end
        if not bash "$SCRIPT_DIR/tools/nvcheck.sh" --release-digests "$response" "$tag" \
            >"$map_file" 2>"$tmp/github-json.err"
        then
            ui_error "$repo: cannot read GitHub release metadata for tag $tag"
            if test -s "$tmp/github-json.err"
                sed 's/^/  /' "$tmp/github-json.err"
            end
            return 2
        end
        printf '%s\n' "$tag" >"$tag_file"
        set found_release 1
        break
    end
    if test $found_release -eq 0
        printf '' >"$map_file"
        printf '' >"$tag_file"
    end
    return 0
end

function github_source_matches_release -a entry repo tag
    if test -z "$tag"
        return 1
    end
    set -l url (source_url "$entry"); or return 1
    set url (string replace -r '[?#].*$' '' -- "$url")
    string match -q "https://github.com/$repo/releases/download/$tag/*" -- "$url"
end

function github_release_asset_name -a entry
    set -l url (source_url "$entry"); or return 1
    set url (string replace -r '[?#].*$' '' -- "$url")
    set -l name (string replace -r '^.*/' '' -- "$url")
    if test -z "$name"
        return 1
    end
    echo "$name"
end

function refresh_package_srcinfo -a pkg_path reason
    if not test -f "$pkg_path/.SRCINFO"
        return 0
    end
    set -l pkg_name (basename "$pkg_path")
    set -l run_as env
    if test "$_ROOT_MODE" = "1"
        set run_as sudo -u "$_BUILD_USER" env HOME=$_BUILD_HOME
    end
    if $run_as makepkg --printsrcinfo --dir "$pkg_path" >"$pkg_path/.SRCINFO.tmp" 2>/dev/null
        if not mv -f -- "$pkg_path/.SRCINFO.tmp" "$pkg_path/.SRCINFO"
            rm -f -- "$pkg_path/.SRCINFO.tmp"
            ui_warning "$pkg_name: $reason but the refreshed .SRCINFO could not replace the committed file"
        end
    else
        rm -f -- "$pkg_path/.SRCINFO.tmp"
        ui_warning "$pkg_name: $reason but the committed .SRCINFO could not be refreshed; regenerate it with 'makepkg --printsrcinfo > .SRCINFO'"
    end
end

# makepkg's own checksum for one VCS source: it hashes `git archive --format tar
# <tag>` of the checkout, so the value is reproducible on any machine and the
# provider's published value is a cross-check rather than a local echo. Prints
# nothing and returns 1 when there is nothing to recompute yet (no checkout, or
# a fragment makepkg itself would answer SKIP for); returns 2 when the
# recomputation was attempted and failed.
function vcs_source_sum -a dir entry alg
    set -l url (source_url $entry); or return 1
    if not string match -q '*#*' -- $url
        return 1
    end
    set -l frag (string replace -r '^[^#]*#' '' -- $url)
    # makepkg appends verification flags to the fragment (#tag=v262?signed);
    # the ref name itself must never carry them or `git archive` looks up a
    # ref that cannot exist and the anchor reports a false checksum mismatch
    # (2026-10-02, systemd). Same rule as the shared source parser.
    set frag (string replace -r '\?signed$' '' -- $frag)
    set -l kind (string replace -r '=.*$' '' -- $frag)
    if test "$kind" != tag; and test "$kind" != commit
        return 1
    end
    set -l val (string replace -r '^[^=]*=' '' -- $frag)
    set -l name (source_filename $entry); or return 1
    # makepkg's get_filename strips a trailing .git from a VCS URL (the clone
    # of …/pipewire.git lands in 'pipewire'), while source_filename keeps the
    # URL spelling the provider map is keyed by — try both spellings, or the
    # checkout is "not available" no matter how healthy it is (2026-09-30).
    set -l name_stripped (string replace -r '\.git$' '' -- $name)
    set -l cands "$dir/$name"
    if test "$name_stripped" != "$name"
        set -a cands "$dir/$name_stripped"
    end
    if set -q SRCDEST; and test -n "$SRCDEST"
        set -a cands "$SRCDEST/$name"
        if test "$name_stripped" != "$name"
            set -a cands "$SRCDEST/$name_stripped"
        end
    end
    set -l repo ""
    for cand in $cands
        if test -d "$cand"
            set repo "$cand"
            break
        end
    end
    if test -z "$repo"
        return 1
    end
    set -l sum_file (mktemp); or return 2
    # The archive is written to a file, not piped: a failing git would
    # otherwise hash empty stdin and report a confident wrong sum. Any git
    # failure (incl. host git hardening on bare repos) is case 2, not a value.
    if not git -c core.abbrev=no -C "$repo" archive --format tar "$val" >"$sum_file" 2>/dev/null
        rm -f -- "$sum_file"
        return 2
    end
    set -l sum (command "$alg"sum <"$sum_file" | string replace -r '\s+.*$' '')
    rm -f -- "$sum_file"
    if test -z "$sum"
        return 2
    end
    echo $sum
end

# ─── Re-anchor moved sources to the selected version provider ────────────────
# A provider version can move a source=() URL away from the bytes described by
# the committed sums. Never treat updpkgsums alone as verification: use a
# provider-published checksum when available, and otherwise report the existing
# loud fetch-only policy.
#
# When a provider publishes no checksum for an entry, refresh it loudly as
# fetch-only instead of claiming the new hash is an anchor. The log and the run
# summary name every such entry and the remaining attestation (PGP for a
# detached signature — already outside this list via source_filename —,
# #tag/#commit for a VCS source, TLS for a plain download). Published values
# remain anchor-or-refuse: verify them after writing and restore on disagreement.
#
# The caller passes only moved entries. In the default Arch path, a pkgver
# rewrite that leaves source=() alone — 26 of the 28 stable recipes pin literal
# versions in their URLs — leaves the committed sums valid, so refusing those
# builds would be a false alarm, and so would re-hashing them.
#
# updpkgsums does the writing, so the recipe keeps its own formatting and its own
# choice of algorithm; the values are then verified against the selected
# provider's, whatever algorithm it publishes, and the check is per-file so a
# disagreement names the file. Every path fails closed, restoring the recipe
# where it was already rewritten.
#
# Return: 0 = anchored (and any refresh-only entries recorded) · 1 = nothing
#         to anchor · 2 = provider/fetch/write failure · 3 = no matching
#         provider metadata · 4 = a source disagrees with a published checksum.
function anchor_sums_from_provider -a pkg_path provider provider_id provider_file
    set -l pkg_name (basename "$pkg_path")
    set -l pkgbase (pkgbuild_var "$pkg_path" pkgbase)
    if test -z "$pkgbase"
        if test "$provider" = aur
            set pkgbase (pkgbuild_base "$pkg_path")
        else
            set pkgbase $pkg_name
        end
    end
    set -l pkgver (pkgbuild_var "$pkg_path" pkgver)
    set -l pkgrel (pkgbuild_var "$pkg_path" pkgrel)
    set -l refuse_manual "  Refresh them by hand — 'updpkgsums' in that recipe, commit, rebuild. '--no-sync' builds the committed version as-is."
    set -l authority_phrase "the official"
    set -l checksum_owner "Arch"
    if test "$provider" = aur
        set authority_phrase "AUR"
        set checksum_owner "AUR"
        set refuse_manual "  No package was built; the recipe was restored. Retry when AUR metadata is available, or use '--no-sync' to build the committed version and sums. Do not treat a fetched hash as an upstream anchor."
    else if test "$provider" = github
        set authority_phrase "GitHub"
        set checksum_owner "GitHub"
        set refuse_manual "  No package was built; the recipe was restored. Retry when GitHub metadata is available, or use '--no-sync' to build the committed version and sums. Do not treat a fetched hash as an upstream anchor."
    end

    # Which of the moved sources a checksum published elsewhere can describe at
    # all: an in-tree file was not downloaded and a signature file gets SKIP.
    set -l anchor_names
    set -l anchor_entries
    for e in $argv[5..-1]
        if test -z (source_url $e)
            continue
        end
        set -l fn (source_filename $e)
        if test -z "$fn"
            continue
        end
        if contains -- $fn $anchor_names
            continue
        end
        set -a anchor_names $fn
        set -a anchor_entries $e
    end
    if test (count $anchor_names) -eq 0
        return 1
    end

    if not type -q curl
        if test "$provider" = arch
            ui_error "$pkg_name: refusing to build — pkgver was synced to $pkgver-$pkgrel and 'curl' is missing, so the official checksums cannot be read"
        else
            ui_error "$pkg_name: refusing to build — pkgver was synced to $pkgver-$pkgrel and 'curl' is missing, so provider checksum metadata cannot be read"
        end
        echo "$refuse_manual"
        return 2
    end
    if not type -q updpkgsums
        ui_error "$pkg_name: refusing to build — pkgver was synced to $pkgver-$pkgrel and 'updpkgsums' is missing, so the sums cannot be refreshed (it ships with pacman)"
        echo "$refuse_manual"
        return 2
    end

    set -l tmp (mktemp -d)

    set -l srcinfo ""
    set -l published "$provider_id"
    set -l map "$tmp/map"
    set -l release_tag ""
    switch "$provider"
        case arch
            # The pkgbase is usually right; some recipes follow a name Arch
            # does not (hip-runtime lives under hip), so try split names too.
            # `main` comes first; the version's own tag is the fallback when
            # the packaging repo has moved past the repo version.
            set -l tried
            set -l seen_pkg ""
            set -l seen_ver ""
            for c in $pkgbase (pkgbuild_array "$pkg_path" pkgname)
                if test -z "$c"
                    continue
                end
                if contains -- $c $tried
                    continue
                end
                set -a tried $c
                for r in main "$pkgver-$pkgrel"
                    set -l f "$tmp/$c-$r.SRCINFO"
                    if not curl -fsSL --max-time 60 -o "$f" "https://gitlab.archlinux.org/archlinux/packaging/packages/$c/-/raw/$r/.SRCINFO" 2>/dev/null
                        continue
                    end
                    if not test -s "$f"
                        continue
                    end
                    # A revision that does not carry our pkgver is no anchor:
                    # it describes different files.
                    set -l v (srcinfo_pkgver "$f")
                    if test -z "$v"
                        continue
                    end
                    if test "$v" = "$pkgver"
                        set srcinfo "$f"
                        set published "$c"
                        break
                    end
                    set seen_pkg "$c"
                    set seen_ver "$v"
                end
                if test -n "$srcinfo"
                    break
                end
            end
            if test -z "$srcinfo"
                if test -n "$seen_ver"
                    ui_error "$pkg_name: refusing to build — pkgver was synced to $pkgver-$pkgrel, but the official packaging repo carries $seen_ver"
                    echo "  (read from the .SRCINFO of the official $seen_pkg packaging repo; anchoring to another version's checksums would describe different files)"
                else
                    ui_error "$pkg_name: refusing to build — pkgver was synced to $pkgver-$pkgrel, and the official Arch packaging repo carries no revision of $pkgbase at that version to anchor the checksums to"
                end
                echo "$refuse_manual"
                command rm -rf -- "$tmp"
                return 3
            end
            srcinfo_sum_map "$srcinfo" >"$map"
            set -l map_status $status
            if test $map_status -ne 0; or not test -s "$map"
                ui_error "$pkg_name: refusing to build — the official .SRCINFO for $published does not line its sources up with its checksums, so it cannot be used as an anchor"
                echo "$refuse_manual"
                command rm -rf -- "$tmp"
                return 3
            end
        case aur
            set srcinfo "$provider_file"
            if not test -s "$srcinfo"; or test (srcinfo_pkgbase "$srcinfo") != "$provider_id"; or test (srcinfo_pkgbase "$srcinfo") != "$pkgbase"; or test (srcinfo_pkgver "$srcinfo") != "$pkgver"
                ui_error "$pkg_name: refusing to build — the AUR .SRCINFO for $provider_id does not match pkgbase $pkgbase and pkgver $pkgver"
                echo "$refuse_manual"
                command rm -rf -- "$tmp"
                return 3
            end
            if not srcinfo_matches_sources "$srcinfo" "$pkg_path"
                ui_error "$pkg_name: refusing to build — the AUR .SRCINFO sources for $provider_id do not exactly match the rewritten recipe"
                echo "$refuse_manual"
                command rm -rf -- "$tmp"
                return 3
            end
            srcinfo_sum_map "$srcinfo" >"$map"
            set -l map_status $status
            if test $map_status -ne 0
                ui_error "$pkg_name: refusing to build — the AUR .SRCINFO for $provider_id does not line its sources up with its checksums"
                echo "$refuse_manual"
                command rm -rf -- "$tmp"
                return 3
            end
        case github
            set -l tag_file "$tmp/release-tag"
            github_release_checksum_map "$provider_id" "$pkgver" "$tmp" "$map" "$tag_file"
            if test $status -ne 0
                echo "$refuse_manual"
                command rm -rf -- "$tmp"
                return 2
            end
            set release_tag (cat "$tag_file" 2>/dev/null)
        case '*'
            ui_error "$pkg_name: refusing to build — unsupported version sync provider '$provider'"
            command rm -rf -- "$tmp"
            return 2
    end

    # Grade before writing. An entry the provider does not cover cannot be
    # anchored to a published value, so it follows the loud refresh-only path.
    # A published digest is still verified after the write; a disagreement
    # refuses and restores.
    set -l refresh_only
    set -l anchor_index 1
    while test $anchor_index -le (count $anchor_names)
        set -l fn $anchor_names[$anchor_index]
        set -l entry $anchor_entries[$anchor_index]
        if test "$provider" = github
            set -l asset_name (github_release_asset_name "$entry")
            if test -z "$asset_name"; or not github_source_matches_release "$entry" "$provider_id" "$release_tag"
                set -a refresh_only $fn
            else if not grep -qF -- (printf '%s\t' "$asset_name") "$map"
                set -a refresh_only $fn
            end
        else if not grep -qF -- (printf '%s\t' $fn) "$map"
            set -a refresh_only $fn
        end
        set anchor_index (math $anchor_index + 1)
    end

    if not cp -- "$pkg_path/PKGBUILD" "$tmp/PKGBUILD.orig"
        ui_error "$pkg_name: cannot back up $pkg_path/PKGBUILD before refreshing the checksums"
        command rm -rf -- "$tmp"
        return 2
    end

    # Write with makepkg's own updater: it preserves the recipe's formatting and
    # keeps whatever checksum algorithm the recipe already uses, and it is also
    # what fetches the sources that step 2 below then verifies.
    if not pushd "$pkg_path" >/dev/null
        ui_error "$pkg_name: cannot enter $pkg_path to refresh the checksums"
        command rm -rf -- "$tmp"
        return 2
    end
    # updpkgsums shells out to makepkg, which refuses to run as root (it exits
    # 10 before it touches the sums). Root mode therefore drops to the invoking
    # user for this step too — the recipe tree is theirs, not root's.
    set -l run_as env
    if test "$_ROOT_MODE" = "1"
        set run_as sudo -u "$_BUILD_USER" env HOME=$_BUILD_HOME
    end
    $run_as updpkgsums >"$tmp/updpkgsums.log" 2>&1
    set -l upd_rc $status
    popd >/dev/null
    if test "$upd_rc" -ne 0
        cp --force -- "$tmp/PKGBUILD.orig" "$pkg_path/PKGBUILD"
        ui_error "$pkg_name: refusing to build — 'updpkgsums' could not refresh the checksums (exit $upd_rc); the recipe was restored"
        tail -5 "$tmp/updpkgsums.log" 2>/dev/null | sed 's/^/  /'
        echo "$refuse_manual"
        command rm -rf -- "$tmp"
        return 2
    end

    # Verify the fetched sources against the provider's values. This is the step
    # that makes the refresh an anchor rather than a rubber stamp, and it is why
    # the algorithm does not have to match: the published hash is checked
    # against the artifact, and the artifact is what the recipe's own hash now
    # describes.
    # A VCS checkout is hashed the way makepkg hashes it (git archive of the
    # tag), because there is no file to run sha256sum on.
    set -l bad
    for i in (seq (count $anchor_names))
        set -l fn $anchor_names[$i]
        # Refresh-only entries have no published value to compare against —
        # they were recorded as fetch-only above; only anchored entries are
        # verified against the selected provider here.
        if contains -- $fn $refresh_only
            continue
        end
        set -l e $anchor_entries[$i]
        set -l map_name "$fn"
        if test "$provider" = github
            set map_name (github_release_asset_name "$e")
        end
        set -l alg (awk -F'\t' -v f="$map_name" '$1==f{print $2}' "$map")
        set -l want (awk -F'\t' -v f="$map_name" '$1==f{print $3}' "$map")
        if not contains -- $alg sha256 sha512 md5 b2
            set -a bad "$fn: $checksum_owner publishes an algorithm this check does not know ('$alg')"
            continue
        end
        set -l got ""
        if source_vcs $e >/dev/null
            set got (vcs_source_sum "$pkg_path" "$e" "$alg")
            switch $status
                case 1
                    set -a bad "$fn: the VCS checkout was not available to recompute $checksum_owner's $alg against"
                    continue
                case 2
                    set -a bad "$fn: 'git archive' could not reproduce the $alg $checksum_owner publishes for this checkout"
                    continue
            end
        else
            set -l file ""
            if test -f "$pkg_path/$fn"
                set file "$pkg_path/$fn"
            else if set -q SRCDEST; and test -n "$SRCDEST"; and test -f "$SRCDEST/$fn"
                set file "$SRCDEST/$fn"
            end
            if test -z "$file"
                set -a bad "$fn: not fetched into the recipe or \$SRCDEST, so $checksum_owner's checksum could not be applied to it"
                continue
            end
            set got (command "$alg"sum "$file" | string replace -r '\s+.*$' '')
        end
        if test "$got" != "$want"
            set -a bad "$fn: $checksum_owner's $alg is $want, the fetched source hashes to $got"
        end
    end
    if test (count $bad) -gt 0
        cp --force -- "$tmp/PKGBUILD.orig" "$pkg_path/PKGBUILD"
        if test "$provider" = arch
            ui_error "$pkg_name: refusing to build — a source does not match the official Arch checksum"
            printf '  %s\n' $bad
            echo "  Nothing was built or installed and the recipe was restored. A source that disagrees with Arch's published checksum is a different source, not a stale sum."
        else
            ui_error "$pkg_name: refusing to build — a source does not match the $checksum_owner published checksum"
            printf '  %s\n' $bad
            echo "  Nothing was built or installed and the recipe was restored. A source that disagrees with $checksum_owner's published checksum is a different source, not a stale sum."
        end
        command rm -rf -- "$tmp"
        return 4
    end

    # Refresh-only entries: say so, here and at run level. This is what keeps
    # the refresh from being a silent weakening — the sums describe what the
    # fetch delivered, so the log names every such entry and what stands behind
    # it, and the run summary (synced.list → print_synced_notes) carries the
    # review/commit instruction to the owner.
    set -l n_refresh (count $refresh_only)
    set -l n_anchored (math (count $anchor_names) - $n_refresh)
    if test $n_refresh -gt 0
        ui_warning "$pkg_name: $authority_phrase $published $pkgver publishes no checksum for (refreshed from the fetch, NOT anchored):"
        printf '  %s\n' $refresh_only
        echo "  Attestation: a detached signature is PGP-verified against the anchored payload at build time, a VCS source is pinned by its #tag/#commit, and a plain download is attested by nothing but the fetch (TLS). Review these sums before committing; '--no-sync' builds the committed version as-is."
    end

    refresh_package_srcinfo "$pkg_path" "the source checksums were updated"

    if test $n_anchored -gt 0
        ui_info "$pkg_name: checksums re-anchored to $authority_phrase $published $pkgver checksums, and verified against the fetched sources"
    else
        ui_info "$pkg_name: checksums refreshed for $pkgver — $authority_phrase $published publishes no checksum for any moved source"
    end
    set -l synced_note "$pkg_name: checksums re-anchored to $authority_phrase $published $pkgver"
    if test $n_refresh -gt 0
        set synced_note "$pkg_name: checksums refreshed at $pkgver — $n_anchored anchored to $authority_phrase $published, $n_refresh refresh-only (fetch-only sums: review before committing)"
    end
    printf '%s\n' "$synced_note" >>"$_STATE_DIR/synced.list" 2>/dev/null
    command rm -rf -- "$tmp"
    return 0
end

function anchor_sums_from_official -a pkg_path
    anchor_sums_from_provider "$pkg_path" arch "" "" $argv[2..-1]
end

# ─── List built package files for a PKGBUILD (all splits, current version) ───
# Multi-split packages (e.g. linux-firmware) produce several *.pkg.tar.zst —
# "ls -t | head -1" would install only one split. Filter by the evaluated
# pkgver-pkgrel so stale packages from previous builds are never installed.
function list_split_pkgs -a pkg_path
    set -l any_archive (find "$pkg_path" -maxdepth 1 -type f \
        -name '*.pkg.tar.zst' -print -quit 2>/dev/null)
    if test -z "$any_archive"
        return 0
    end
    set -l metadata (pkgbuild_version "$pkg_path")
    set -l metadata_status $status
    if test $metadata_status -ne 0; or test (count $metadata) -ne 2
        ui_error "$(basename "$pkg_path"): could not evaluate pkgver/pkgrel for archive discovery" >&2
        return 0
    end
    set -l pv (string replace -r '^pkgver=' '' -- "$metadata[1]")
    set -l pr (string replace -r '^pkgrel=' '' -- "$metadata[2]")
    # find (not fish globs): an unmatched glob is a FATAL error in fish, and
    # 2>/dev/null does not suppress it. find -name returns 0 with no matches.
    # Unknown version metadata cannot prove an archive current; never broaden
    # discovery to every archive when the version-specific pattern is unknown.
    if test -z "$pv" -o -z "$pr"
        return 0
    end
    find "$pkg_path" -maxdepth 1 -name "*$pv-$pr-*.pkg.tar.zst" 2>/dev/null | sort
end

# ─── Workspace-wide built-package helpers ────────────────────────────────────
function find_pkg_dirs
    for entry in $_PACKAGE_MAP
        set -l fields (string split '|' -- "$entry")
        echo "$SCRIPT_DIR/$fields[2]"
    end
end

# All current-version *.pkg.tar.zst across the workspace. Stale archives from
# previous pkgver/pkgrel builds are excluded (install-only; cleanup gets all).
function find_built_pkgs
    for d in (find_pkg_dirs)
        list_split_pkgs "$d"
    end
end

# -ia / --installall: install everything already built in ONE pacman
# transaction (inter-package deps resolve within the transaction).
# Extra args are forwarded to pacman, e.g.: build-all.fish -ia --overwrite '*'
# This entry is FORCE mode: it deliberately has NO same-version skip (2026-09-26
# decision) but shares the one install pipeline — the same install_plan +
# install_execute the -i path uses, so there is no second implementation of
# the PGO gate, the transaction, or the transcript rules.
function install_all
    if not require_command flock; or not require_command pacman
        return 1
    end
    # -ia returns before run_lanes, so check_runtime_prereqs never runs for it.
    # The PGO gate needs both: tar unrolls the archive, strings reads it.
    if not require_command tar; or not require_command strings
        return 1
    end
    if test "$_ROOT_MODE" != "1"; and not require_command sudo
        return 1
    end
    # ONE preflight shared with -i (install_preflight): a busy db.lck or a
    # broken local entry would hard-fail the whole single transaction anyway —
    # refuse up front with the recovery text.
    if not install_preflight refuse "start -ia"
        return 1
    end
    set -l pkgs (find_built_pkgs)
    if test (count $pkgs) -eq 0
        # Force mode remains a no-op when no archive can be identified at its
        # PKGBUILD's current evaluated pkgver-pkgrel.
        ui_warning "No eligible built packages found."
        return 0
    end
    ui_heading "Installing "(count $pkgs)" packages"
    for p in $pkgs
        echo "  $p"
    end
    # $pkgs are absolute (find_pkg_dirs → $SCRIPT_DIR) — safe under any cwd.
    if not ensure_state_dirs
        return 1
    end
    set -l install_log "$LOG_DIR/install-all.log"
    # The plan is computed once and consumed by the executor (silent: the
    # heading above is the only plan rendering this entry adds).
    set -l plan (install_plan force $pkgs)
    install_execute "$install_log" loud (count $argv) $argv $plan
end

# ─── PGO payload gate (an install-plan step) ─────────────────────────────────
# An installed PGO *phase-1* binary bakes absolute profile destinations into
# `.rodata` — `.gcda` for C/C++ `-fprofile-generate`, `.profraw` for Rust's
# `-Cprofile-generate` — and its runtime recreates that entire tree on every
# invocation: libgcov for the C path, the LLVM profile runtime for Rust. The
# 2026-09-20 incident: `cmake`, `ccmake`, `cpack`, `ctest` and `Xwayland`
# rebuilt .Heavyweight/cmake-git and xorg-xwayland-git in full (779 files) from
# one command each. The damage lands only once such a package is INSTALLED, so
# this gates the install: an instrumented archive that never reaches pacman is
# inert.
#
# makepkg strips the payload before it writes the archive (no PGO recipe sets
# `!strip`), so the symbol test the recipes run inside `package()` —
# `readelf -sW | grep -E '__gcov_|__llvm_profile'` — is blind here: it returns
# clean on a stripped binary that still carries 431 baked paths. The path string
# is what survives stripping, so that is what this looks for.
#
# The whole archive is inspected, with no member filter: instrumentation can
# live in a helper under usr/libexec or opt just as well as in usr/bin, and
# scoping to the obvious two directories would miss exactly those. Precision
# comes from the predicate instead — it matches a *standalone* absolute path, so
# valid metadata (.BUILDINFO, .PKGINFO record no `.gcda`/`.profraw` at all),
# prose docs,
# and a source comment quoting a path all pass while a real baked destination
# does not. Gating on the recipe keeps the extract cost on the few recipes that
# can leak, and covers a recipe that *starts* instrumenting with no further edit
# here. Both spellings of the instrumenting flag count: the C `-fprofile-generate`
# and rustc's `-Cprofile-generate` (mold-git's self-relink PGO).
#
# The char class after the leading slash excludes `/` and `*` for that reason:
# a glob literal is not a standalone path, and `ctest` (CMake's coverage tool)
# legitimately ships `/*.gcda` in its own GCOV support. Without the exclusion a
# correctly rebuilt cmake-git is refused at install, which is how the 2026-09-20
# rebuild of cmake-git failed *after* its payload came out clean.
#
# This is the DECISION half: it emits install-plan rows and stays silent —
# install_execute renders the refusal messages from these rows, and the
# --install-decide fixture seam prints them verbatim. Row shapes (fields are
# space-separated; a member name containing a space would truncate its row,
# which still refuses correctly):
#   refuse pgo-temp <archive>
#   refuse pgo-unreadable <archive> <tar-rc> <extracted-files>
#   refuse pgo-hit <archive> <member>          (one per offending member)
#   refuse pgo-instrumented <archive>          (the verdict for that archive)
# Returns 0 for every archive that is clean or not applicable, 1 after any
# refusal row. Callers abort: an instrumented payload must never be installed,
# and under `-i` every later package would compile against it.
function pgo_payload_refusals
    set -l failed 0
    for archive in $argv
        set -l recipe_dir (dirname -- "$archive")
        if not grep -Eq -- '-fprofile-generate|-C ?profile-generate' "$recipe_dir/PKGBUILD" 2>/dev/null
            continue
        end
        set -l tmp_root "$TMPDIR"
        if test -z "$tmp_root"
            set tmp_root /tmp
        end
        set -l work (mktemp -d "$tmp_root/gsa-pgo-verify.XXXXXX" 2>/dev/null)
        if test -z "$work"
            echo "refuse pgo-temp $archive"
            set failed 1
            continue
        end
        # GNU tar restores the whole archive — nothing is filtered out. A
        # non-zero status, or an archive that yields no files at all, means the
        # payload could not be read; an unverified PGO payload is exactly what
        # this exists to prevent, so that fails closed instead of passing by
        # default.
        tar --zstd -xf "$archive" -C "$work" 2>/dev/null
        set -l tar_rc $status
        set -l extracted (count (find "$work" -type f 2>/dev/null))
        if test "$tar_rc" -ne 0; or test "$extracted" -eq 0
            rm -rf -- "$work"
            echo "refuse pgo-unreadable $archive $tar_rc $extracted"
            set failed 1
            continue
        end
        # `strings -f` prefixes every line with its file, so one invocation
        # covers the whole payload and still names the offender. The scan runs
        # from inside $work, so the reported paths are relative to the archive.
        set -l hits (cd "$work"; and find . -type f -exec strings -a -f {} + 2>/dev/null \
            | grep -E '^[^:]+: /[^[:space:]/*][^[:space:]]*\.(gcda|profraw)' \
            | cut -d: -f1 | sort -u)
        rm -rf -- "$work"
        if test (count $hits) -gt 0
            for hit in $hits
                echo "refuse pgo-hit $archive $hit"
            end
            echo "refuse pgo-instrumented $archive"
            set failed 1
        end
    end
    if test "$failed" = "1"
        return 1
    end
    return 0
end

function run_pacman_locked -a log_file
    set -l command_name $argv[2]
    set -l command_args $argv[3..-1]
    if test -z "$command_name"
        ui_error "internal error: pacman command is empty" >&2
        return 2
    end
    # Mutex file contract: flock(1) creates it if absent (with the umask), so
    # root mode pre-creates it AS THE BUILD USER and repairs an owner left by
    # an interrupted root run — a later unprivileged run must be able to open
    # it (measured: flock opens read-only, so a root-owned 0644 lock still
    # works, but 0600 would not). Never replace an EXISTING lock inode:
    # renaming a mutex file splits exclusion between concurrent runs.
    if not test -e "$_PACMAN_MUTEX"
        if test "$_ROOT_MODE" = "1"
            if not sudo -u "$_BUILD_USER" touch "$_PACMAN_MUTEX" 2>/dev/null
                ui_error "cannot create pacman mutex as $_BUILD_USER: $_PACMAN_MUTEX"
                return 2
            end
        else if not touch "$_PACMAN_MUTEX" 2>/dev/null
            ui_error "cannot create pacman mutex: $_PACMAN_MUTEX"
            log_ownership_hint
            return 2
        end
    else if test "$_ROOT_MODE" = "1"
        chown "$_BUILD_USER": "$_PACMAN_MUTEX" 2>/dev/null
    else if not test -r "$_PACMAN_MUTEX"
        ui_error "cannot read pacman mutex: $_PACMAN_MUTEX"
        log_ownership_hint
        return 2
    end
    printf '%s\n' "$_UI_ICON_INFO waiting for builder pacman mutex: $_PACMAN_MUTEX" >&2
    flock -x -w "$_PACMAN_MUTEX_WAIT" "$_PACMAN_MUTEX" \
        "$command_name" $command_args
    set -l rc $status
    if test "$rc" -eq 75
        printf '%s\n' "$_UI_ICON_ERROR builder pacman mutex timed out after $_PACMAN_MUTEX_WAIT seconds" >&2
    end
    if test "$rc" -ne 0
        # Lock-failure path (install_pkgs_now and -ia funnel through here): a
        # failed pacman commonly means db.lck — report holders, or clear a
        # provably stale lock so the NEXT attempt can proceed (2026-09-23:
        # six runs died on "could not lock database: File exists").
        check_pacman_lock (pacman_db_lock_path)
        # The other failure this path actually sees is pacman's misleading
        # "invalid or corrupted package", which is the LOCAL db, not the
        # archive (2026-09-24 vscodium): probe/repair the broken entry right
        # here so the retry or the next run can succeed.
        check_pacman_db_health (pacman_db_local_path)
    end
    return $rc
end

# makepkg's `-s` syncdeps runs pacman THROUGH $PACMAN, OUTSIDE the builder's
# flock (run_pacman in /usr/bin/makepkg: `PACMAN=${PACMAN:-pacman}` ~line
# 1203, resolved as PACMAN_PATH=$(type -P $PACMAN) for both -T probes and -S
# installs — verified 2026-09-23). Six dep-pacmans raced the builder's
# `pacman -U` at 19:33:58 that day. The shim pins those calls to the SAME
# mutex run_pacman_locked uses. No deadlock: run_pacman_locked is a leaf
# (flock → /usr/bin/pacman directly, never re-entering makepkg), so the lock
# order cannot cycle. On flock timeout rc=75 propagates as a loud dep-install
# failure — the accepted outcome.
function ensure_pacman_shim
    if not ensure_state_dirs
        return 1
    end
    set -l shim "$LOG_DIR/.pacman-shim"
    set -l tmp "$shim.tmp.$fish_pid"
    # %d → _PACMAN_MUTEX_WAIT; mutex path baked absolute; "$@" is literal sh.
    if not printf '#!/bin/sh\n# build-all.fish: makepkg -s dep installs must share the builder mutex.\nexec flock -x -w %d %s /usr/bin/pacman "$@"\n' \
            "$_PACMAN_MUTEX_WAIT" "$_PACMAN_MUTEX" >"$tmp"
        rm -f -- "$tmp"
        return 1
    end
    if not chmod 755 "$tmp"
        rm -f -- "$tmp"
        return 1
    end
    # Write-time ownership: publish the shim as the build user (the exec'ing
    # makepkg runs as them; a SIGKILL between here and mv only strands a
    # .tmp file, never a root-owned shim — the next run replaces it by rename).
    if test "$_ROOT_MODE" = "1"; and not chown "$_BUILD_USER": "$tmp" 2>/dev/null
        rm -f -- "$tmp"
        return 1
    end
    # Atomic replace: a lane already executing the old inode keeps running.
    if not mv -f -- "$tmp" "$shim"
        rm -f -- "$tmp"
        return 1
    end
    return 0
end

# -cc / --cleanup: delete every built package archive (including stale
# old-version files that list_split_pkgs would skip).
function cleanup_pkgs
    set -l pkgs (find "$SCRIPT_DIR/packages" -type f -name '*.pkg.tar.zst' \
        -not -path '*/src/*' -not -path '*/pkg/*' 2>/dev/null | sort)
    set -l manifests (find "$SCRIPT_DIR/packages" -type f -name '*.pkg.tar.zst.gsa-vcs-revisions' \
        -not -path '*/src/*' -not -path '*/pkg/*' 2>/dev/null | sort)
    if test (count $pkgs) -eq 0; and test (count $manifests) -eq 0
        echo "No built packages or VCS revision metadata to remove."
        return 0
    end
    set -l size 0
    if test (count $pkgs) -gt 0
        set size (du -ch $pkgs | tail -1 | cut -f1)
    end
    set -l targets $pkgs $manifests
    echo "Removing "(count $pkgs)" package archives ("$size") and "(count $manifests)" VCS revision records"
    if not rm -v -- $targets
        ui_error "failed to remove one or more package archives"
        return 1
    end
end

# ─── Nuclear cleanup (-ccc / --nuclear) ──────────────────────────────────────
# Wipes everything makepkg pulled/built EXCEPT the built package archives
# (those are -cc's job). Per package dir this removes:
#   - src/, pkg/, build/ and _build/ staging dirs
#   - the source VCS checkouts makepkg created next to the PKGBUILD
#     (SRCDEST defaults to $startdir: cairo-git/cairo, packages/core/llvm-git/llvm-project,
#     texlive-texmf/texmf-dist, ...)
#   - downloaded source files (*.tar.* and *.whl, incl. .sig/.asc companions
#     and .part)
# Source names come from each PKGBUILD's source=() array, resolved in bash so
# entries like git+${url}.git, svn://…#revision=N or name::URL match exactly
# what makepkg fetches.
# Local support files (patches, hooks, keys/, .nvchecker.toml) are never touched.
# Symlinks are NEVER deleted nor followed: deliberately shared sources — e.g.
# llvm-project symlinked into spirv-llvm-translator-git to save storage — are
# listed as preserved and left intact.
function nuclear_cleanup
    if test "$_ROOT_MODE" != "1"; and not require_command sudo
        return 1
    end
    set -l all_targets
    set -l all_skipped

    for d in (find_pkg_dirs)
        set -l pkg_targets
        set -l pkg_skipped

        # Staging / build dirs (skip symlinks — may be deliberate links to
        # shared storage)
        for sub in src pkg build _build
            if test -L "$d/$sub"
                set -a pkg_skipped "$d/$sub"
            else if test -d "$d/$sub"
                set -a pkg_targets "$d/$sub"
            end
        end

        # Sources as makepkg sees them
        set -l sources (bash -c "source '$d/PKGBUILD' 2>/dev/null && printf '%s\n' \"\${source[@]}\"" 2>/dev/null)
        for s in $sources
            set -l name ""
            set -l url "$s"
            if string match -q '*::*' -- "$s"
                set -l parts (string split -m 1 '::' -- "$s")
                set name $parts[1]
                set url $parts[2]
            end

            if string match -q 'git+*' -- "$url"
                # VCS source → makepkg clones it as $SRCDEST/<name> (next to the PKGBUILD)
                if test -z "$name"
                    set name (string replace -r '^git\+' '' -- "$url" \
                        | string replace -r '[?#].*$' '' \
                        | string replace -r '/$' '' \
                        | string replace -r '\.git$' '')
                    set name (basename "$name")
                end
                if test -n "$name" -a "$name" != . -a "$name" != .. -a -d "$d/$name"
                    if test -L "$d/$name"
                        # Deliberate source sharing (e.g. llvm-project) — keep it
                        set -a pkg_skipped "$d/$name"
                    else
                        set -a pkg_targets "$d/$name"
                    end
                end
            else if string match -qr '^svn\+|^svn://' -- "$url"
                # SVN source → makepkg checks it out as $SRCDEST/<basename>
                # (get_filename: basename with the fragment removed), keeping
                # it in sync with `svn update -r` on rebuild. svn:// is used
                # without a svn+ prefix by some recipes, hence both matches.
                if test -z "$name"
                    set name (basename (string replace -r '/$' '' -- (string replace -r '[?#].*$' '' -- (string replace -r '^svn\+' '' -- "$url"))))
                end
                if test -n "$name" -a "$name" != . -a "$name" != .. -a -d "$d/$name"
                    if test -L "$d/$name"
                        set -a pkg_skipped "$d/$name"
                    else
                        set -a pkg_targets "$d/$name"
                    end
                end
            else if string match -qr '^(https?|ftp)://' -- "$url"
                # Remote file source → only downloaded archives; plain local
                # entries (patches, hooks, keyrings) never match a URL here
                set -l fname "$name"
                if test -z "$fname"
                    set fname (basename (string replace -r '[?#].*$' '' -- "$url"))
                end
                set -l is_download_archive 0
                for _ext in $_DOWNLOAD_ARCHIVE_EXTS
                    if string match -q "*.$_ext" -- "$fname"
                        set is_download_archive 1
                        break
                    end
                end
                if test $is_download_archive -eq 1
                    if test -f "$d/$fname"; and not test -L "$d/$fname"
                        set -a pkg_targets "$d/$fname"
                    end
                end
                for ext in sig asc sign
                    if test -f "$d/$fname.$ext"; and not test -L "$d/$fname.$ext"
                        set -a pkg_targets "$d/$fname.$ext"
                    end
                end
                if test -f "$d/$fname.part"; and not test -L "$d/$fname.part"
                    set -a pkg_targets "$d/$fname.part"
                end
            end
        end

        if test (count $pkg_skipped) -gt 0
            printf '%s%s%s\n' (set_color yellow) "$d — symlinks preserved" (set_color normal)
            for t in $pkg_skipped
                echo "  ↷ kept: $t"
            end
            set -a all_skipped $pkg_skipped
        end

        if test (count $pkg_targets) -gt 0
            # Dedupe (a sig file can be both a source entry and a companion)
            set pkg_targets (printf '%s\n' $pkg_targets | awk '!seen[$0]++')

            printf '%s%s%s\n' (set_color cyan) "$d" (set_color normal)
            for t in $pkg_targets
                set -l sz (du -sh "$t" 2>/dev/null | cut -f1)
                printf '  %-8s %s\n' "$sz" "$t"
                set -a all_targets "$t"
            end
        end
    end

    if test (count $all_targets) -eq 0
        if test (count $all_skipped) -eq 0
            echo "Nothing to clean — no pulled sources found."
            return 0
        end
        echo "Nothing to delete — all found sources are preserved symlinks."
        return 0
    end

    set -l total (du -sch $all_targets 2>/dev/null | tail -1 | cut -f1)
    echo ""
    printf '%s%s%s\n' (set_color red) "☢ NUCLEAR: will delete "(count $all_targets)" targets ("$total")" (set_color normal)
    if test (count $all_skipped) -gt 0
        printf '%s%s%s\n' (set_color yellow) "  "(count $all_skipped)" symlink(s) preserved." (set_color normal)
    end
    echo "  Built package archives are kept — run -cc to remove those too."
    read -P "Proceed? [y/N] " -l answer
    if not string match -qi 'y*' -- "$answer"
        echo "Aborted — nothing deleted."
        return 0
    end

    for t in $all_targets
        # Safety net: never touch anything outside the workspace
        if string match -q "$SCRIPT_DIR/*" -- "$t"
            if test "$_ROOT_MODE" = "1"
                if not rm -rf -- "$t"
                    ui_error "failed to remove cleanup target: $t"
                    return 1
                end
            else if not sudo rm -rf -- "$t"
                ui_error "failed to remove cleanup target: $t"
                return 1
            end
        else
            ui_warning "skipped cleanup target outside workspace: $t"
        end
    end
    ui_success "Nuclear cleanup complete."
end

# ─── Workspace audit lints (recipe contract) ─────────────────────────────────
# One implementation per rule, two consumers: audit_workspace renders these
# into --audit's report and the hidden --audit-lint seam (bottom of this file)
# runs one of them against the loaded workspace. tests/recipe-contract.sh is
# the gating walker. All three lints are REPORT-ONLY everywhere: a finding
# never changes an exit status. Inputs are the committed .SRCINFO files — the
# same metadata install/depends decisions read — PKGBUILD is never evaluated.
#
# Rules (docs/MEMORY.md provides discipline + purged tools + IgnorePkg closure):
#   provides   a VERSIONED name-provide wherever some workspace consumer
#              constrains that name (an unversioned provide cannot satisfy
#              `>=N`, so pacman silently falls back to the repo package — the
#              meson incident class), and BARE soname stems (`libfoo.so`,
#              never `libfoo.so=2-64`: makepkg auto-versions a bare stem from
#              the built ELF, a hand-pinned one only rots).
#   purged     host-purged tools must not re-enter through makedepends/
#              checkdepends (makepkg reinstalls them silently).
#   ignorepkg  every workspace pkgbase/pkgname must sit in the host's
#              IgnorePkg closure, read the way pacman reads /etc/pacman.conf:
#              repeated IgnorePkg lines inside [options] ACCUMULATE, and a
#              line inside a repo section — or before any section — is
#              dropped. An [options] Include cannot be followed here, so it
#              is reported instead of silently under-counting the closure.

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
    set -l entries # id|provide-value — every provide in the set
    for entry in $_PACKAGE_MAP
        set -l fields (string split '|' -- "$entry")
        set -l id $fields[1]
        set -l srcinfo "$SCRIPT_DIR/$fields[2]/.SRCINFO"
        test -f "$srcinfo"; or continue
        for field in depends makedepends optdepends checkdepends
            for value in (sed -n "s/^[[:space:]]*$field = //p" "$srcinfo" 2>/dev/null)
                # optdepends carry a `: description` suffix; names never do.
                set -l v (string split -m1 ':' -- "$value")[1]
                set -l m (string match -r -g '^(.+?)(>=|<=|=|>|<)(.+)$' -- (string trim -- $v))
                test (count $m) -ge 3; or continue
                set -a constraints "$m[1]|$m[2]|$m[3]|$id"
            end
        end
        for value in (sed -n 's/^[[:space:]]*provides = //p' "$srcinfo" 2>/dev/null)
            set -a entries "$id|$value"
        end
    end

    set -l findings
    for entry in $entries
        set -l parts (string split -m 1 '|' -- $entry)
        set -l id $parts[1]
        set -l value $parts[2]
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
    for entry in $_PACKAGE_MAP
        set -l fields (string split '|' -- "$entry")
        set -l id $fields[1]
        set -l srcinfo "$SCRIPT_DIR/$fields[2]/.SRCINFO"
        test -f "$srcinfo"; or continue
        for field in makedepends checkdepends
            for value in (sed -n "s/^[[:space:]]*$field = //p" "$srcinfo" 2>/dev/null)
                set -l v (string split -m1 ':' -- "$value")[1]
                set -l m (string match -r -g '^(.+?)(>=|<=|=|>|<)(.+)$' -- (string trim -- $v))
                set -l name $v
                test (count $m) -ge 3; and set name $m[1]
                if contains -- "$name" $denylist
                    set -a findings "purged: $id: $field reintroduces purged tool '$name' — remove it (docs/MEMORY.md rule 8)"
                end
            end
        end
    end
    if test (count $findings) -gt 0
        printf '%s\n' $findings | sort -u
    end
    return 0
end

function audit_lint_ignorepkg -a conf
    test -n "$conf"; or set conf /etc/pacman.conf
    # Names under test: the documented closure is pkgbase+pkgname from every
    # committed .SRCINFO (docs/MEMORY.md rule 9's verification procedure).
    set -l names
    for entry in $_PACKAGE_MAP
        set -l fields (string split '|' -- "$entry")
        set -l srcinfo "$SCRIPT_DIR/$fields[2]/.SRCINFO"
        test -f "$srcinfo"; or continue
        for name in (sed -n 's/^\(pkgbase\|pkgname\) = //p' "$srcinfo" 2>/dev/null)
            set -a names "$name"
        end
    end
    if test (count $names) -gt 0
        set names (printf '%s\n' $names | sort -u)
    end

    if not test -r "$conf"
        echo "ignorepkg: skipped — $conf is not readable"
        return 0
    end
    # pacman.conf semantics: directives count only inside their section, so
    # the section tracker starts OUTSIDE [options] — a line before any section
    # header belongs to no section and is dropped, exactly like a repo
    # section's IgnorePkg line.
    set -l ignored
    set -l findings
    set -l in_options 0
    for raw in (cat "$conf")
        set -l line (string trim -- (string split -m1 '#' -- "$raw")[1])
        test -n "$line"; or continue
        if string match -qr '^\[.+\]$' -- "$line"
            set -l sec (string replace -r '^\[(.+)\]$' '$1' -- "$line")
            if test (string trim -- "$sec") = options
                set in_options 1
            else
                set in_options 0
            end
            continue
        end
        test $in_options -eq 1; or continue
        if string match -qr '^Include[[:space:]]*=' -- "$line"
            set -a findings "ignorepkg: $conf: [options] Include is not followed — inline its IgnorePkg entries into the file"
            continue
        end
        set -l m (string match -r -g '^IgnorePkg[[:space:]]*=[[:space:]]*(.*)$' -- "$line")
        test (count $m) -ge 1; or continue
        set -a ignored (string split -n ' ' -- (string replace -a \t ' ' -- $m[1]))
    end
    for name in $names
        contains -- "$name" $ignored; and continue
        set -a findings "ignorepkg: $name is not in the IgnorePkg closure of $conf"
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
    for entry in $_PACKAGE_MAP
        set -l fields (string split '|' -- "$entry")
        set -l id $fields[1]
        test "$id" = rust-git; and continue
        set -l recipe "$SCRIPT_DIR/$fields[2]"
        set -l toolchain_lines (grep -E '^[[:space:]]*[^#[:space:]]' "$recipe/PKGBUILD" 2>/dev/null \
            | grep -Ec '(^|[^[:alnum:]_])(cargo|rustc)([^[:alnum:]_]|$)')
        test -n "$toolchain_lines"; or set toolchain_lines 0
        test "$toolchain_lines" -gt 0; or continue
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
    echo "IgnorePkg closure:"
    set -l ignorepkg_findings (audit_lint_ignorepkg '')
    if test (count $ignorepkg_findings) -eq 0
        echo "  none"
    else
        for finding in $ignorepkg_findings
            echo "  $finding"
        end
    end

    echo ""
    echo "Stale runtime/error artifacts:"
    set -l stale (find "$LOG_DIR" -maxdepth 1 -type f \
        \( -name '.lane*.result' -o -name '*.srcinfo.err' \) \
        -printf '%p\n' 2>/dev/null)
    if test (count $stale) -eq 0
        echo "  none"
    else
        for path in $stale
            echo "  $path"
        end
    end
    set -l package_errors (find "$SCRIPT_DIR/packages" -name '.srcinfo.err' \
        -not -path '*/src/*' -not -path '*/pkg/*' -printf '%p\n' 2>/dev/null)
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
    for entry in $_PACKAGE_MAP
        set -l fields (string split '|' -- "$entry")
        set -l recipe "$SCRIPT_DIR/$fields[2]"
        grep -Eq -- '-fprofile-generate|-C ?profile-generate' "$recipe/PKGBUILD" 2>/dev/null; or continue
        # Names come from .SRCINFO, never PKGBUILD: the kernel assigns pkgbase
        # in a variable, so PKGBUILD scraping would misreport it as absent.
        for name in (sed -n 's/^pkgname = //p' "$recipe/.SRCINFO" 2>/dev/null)
            set -a pgo_names "$name"
        end
    end
    if test (count $pgo_names) -gt 0
        set pgo_names (printf '%s\n' $pgo_names | awk '!seen[$0]++')
    end
    set -l pgo_list (mktemp 2>/dev/null)
    set -l pgo_absent
    if test -n "$pgo_list"
        for name in $pgo_names
            if not pacman -Qq -- "$name" >/dev/null 2>&1
                set -a pgo_absent "$name"
                continue
            end
            LANG=C pacman -Ql -- "$name" 2>/dev/null | awk '$2 !~ /\/$/ {print $2}'
        end > $pgo_list
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
    test -n "$pgo_list"; and rm -f $pgo_list

    echo ""
    echo "Historical references in docs/NOTE.md are not treated as active"
    echo "configuration by this audit."
end

# ─── Shared-source linking (-ln / --link-sources) ────────────────────────────
# Deduplicates git source clones: groups every PKGBUILD's git+ sources by
# effective URL (fragments like #tag/#branch are stripped — one mirror can
# serve several refs) and symlinks the twins to one canonical mirror, e.g.
#   packages/core/llvm-git/llvm-project  ← packages/git/libclc-git/llvm-project-git
#   packages/core/rocm-llvm/rocm-llvm    ← packages/stable/hip-runtime/hip-runtime-hipcc
# Canonical selection prefers an existing valid mirror, then core paths.
# A missing canonical is fine: the twin symlink dangles until the canonical
# package's first build, where makepkg clones THROUGH the symlink into it.
# Also repairs canonical mirrors: remote.origin.url must equal the PKGBUILD
# URL (makepkg aborts "is not a clone of" otherwise) and remote.origin.fetch
# must exist (a missing refspec makes 'fetch --all' a silent no-op); warns
# about insteadOf redirects that mask where fetches actually go.
# makepkg uses `git clone -s` (alternates) for working copies, so deleting a
# twin clone also deletes its src/ working copy (recreated on next build).
function valid_source_mirror -a path
    test -d "$path"; or return 1

    # Do not let git discover the enclosing package repository when a stale
    # empty source directory is present (for example packages/core/llvm-git/llvm-project).
    set -l abs_path (realpath "$path" 2>/dev/null)
    test -n "$abs_path"; or return 1
    set -l git_dir (git -c safe.bareRepository=all -C "$path" \
        rev-parse --absolute-git-dir 2>/dev/null)
    test -n "$git_dir"; or return 1
    set git_dir (realpath "$git_dir" 2>/dev/null)
    test -n "$git_dir"; or return 1

    if test "$git_dir" = "$abs_path"; \
        and test (git -c safe.bareRepository=all -C "$path" \
            rev-parse --is-bare-repository 2>/dev/null) = true
        return 0
    end

    set -l top (git -c safe.bareRepository=all -C "$path" \
        rev-parse --show-toplevel 2>/dev/null)
    test -n "$top"; and test (realpath "$top" 2>/dev/null) = "$abs_path"
end

function link_sources
    set -l entries

    # Collect git sources as "effectiveURL|localName|pkgDir"
    for d in (find_pkg_dirs)
        set -l srcs (bash -c "source '$d/PKGBUILD' 2>/dev/null && printf '%s\n' \"\${source[@]}\"" 2>/dev/null)
        for s in $srcs
            set -l name ""
            set -l url "$s"
            if string match -q '*::*' -- "$s"
                set -l parts (string split -m 1 '::' -- "$s")
                set name $parts[1]
                set url $parts[2]
            end
            if not string match -q 'git+*' -- "$url"
                continue
            end
            set -l eff (string replace -r '^git\+' '' -- "$url" | string replace -r '[?#].*$' '')
            if test -z "$name"
                set name (string replace -r '\.git$' '' -- (basename (string replace -r '/$' '' -- "$eff")))
            end
            set -a entries "$eff|$name|$d"
        end
    end

    if test (count $entries) -eq 0
        echo "No git sources found."
        return 0
    end

    set -l urls (printf '%s\n' $entries | cut -d'|' -f1 | sort -u)
    set -l deletions
    set -l del_twins
    set -l n_ok 0
    set -l n_fix 0
    set -l n_error 0

    for u in $urls
        set -l members (printf '%s\n' $entries | grep -F -- "$u|")
        if test (count $members) -lt 2
            continue
        end

        # Rank members: valid real mirror > valid symlink > missing; core >
        # other paths. Existing non-git directories are never treated as
        # mirrors; an empty one can be replaced, while a populated one is
        # left untouched and reported below.
        set -l ranked
        for m in (printf '%s\n' $members | sort)
            set -l parts (string split '|' -- "$m")
            set -l p "$parts[3]/$parts[2]"
            set -l key 2
            if valid_source_mirror "$p"
                if test -L "$p"
                    set key 1
                else
                    set key 0
                end
            else if test -d "$p"; and not test -L "$p"
                set -l child (find "$p" -mindepth 1 -maxdepth 1 \
                    -print -quit 2>/dev/null)
                if test -n "$child"
                    set key 3
                end
            end
            if string match -q "$SCRIPT_DIR/packages/core/*" -- "$parts[3]"
                set key "$key"0
            else
                set key "$key"1
            end
            set -a ranked "$key|$m"
        end
        set ranked (printf '%s\n' $ranked | sort | cut -d'|' -f2-)

        set -l canon (string split '|' -- "$ranked[1]")
        set -l canon_dir "$canon[3]"
        set -l canon_path "$canon_dir/$canon[2]"

        printf '%s%s%s\n' (set_color cyan) "shared mirror: $u" (set_color normal)
        echo "  canonical: $canon_path"

        # Repair the canonical mirror when it is a real clone
        if valid_source_mirror "$canon_path"
            set -l origin (git -c safe.bareRepository=all -C "$canon_path" \
                config --get remote.origin.url 2>/dev/null)
            if test "$origin" != "$u"
                if git -c safe.bareRepository=all -C "$canon_path" \
                    remote set-url origin "$u"
                    printf '%s%s%s\n' (set_color yellow) "  ↻ fixed origin: '$origin' → '$u'" (set_color normal)
                    set n_fix (math $n_fix + 1)
                else
                    ui_error "cannot repair mirror origin: $canon_path"
                    set n_error (math $n_error + 1)
                    continue
                end
            end
            set -l refspec (git -c safe.bareRepository=all -C "$canon_path" \
                config --get-all remote.origin.fetch 2>/dev/null)
            if test -z "$refspec"
                if git -c safe.bareRepository=all -C "$canon_path" \
                    config remote.origin.fetch "+refs/*:refs/*"
                    printf '%s%s%s\n' (set_color yellow) "  ↻ added missing remote.origin.fetch refspec (fetch was a silent no-op)" (set_color normal)
                    set n_fix (math $n_fix + 1)
                else
                    ui_error "cannot repair mirror fetch refspec: $canon_path"
                    set n_error (math $n_error + 1)
                    continue
                end
            else if test (git -c safe.bareRepository=all -C "$canon_path" \
                config --get core.bare 2>/dev/null) = true; and test "$refspec" != '+refs/*:refs/*'
                printf '%s%s%s\n' (set_color yellow) "  ⚠ bare mirror with non-mirror refspec '$refspec' — won't fetch tags/pull refs" (set_color normal)
            end
            set -l io (git -c safe.bareRepository=all -C "$canon_path" \
                config --local --list 2>/dev/null | grep -i insteadof)
            if test -n "$io"
                printf '%s%s%s\n' (set_color yellow) "  ⚠ insteadOf redirect present — fetches do NOT go to '$u'" (set_color normal)
            end
        else if test -d "$canon_path"; and not test -L "$canon_path"
            set -l child (find "$canon_path" -mindepth 1 -maxdepth 1 \
                -print -quit 2>/dev/null)
            if test -z "$child"
                if rmdir "$canon_path"
                    printf '%s%s%s\n' (set_color yellow) "  ↻ removed stale empty mirror directory" (set_color normal)
                else
                    ui_error "cannot remove stale empty mirror directory: $canon_path"
                    set n_error (math $n_error + 1)
                    continue
                end
            else
                printf '%s%s%s\n' (set_color red) "  ✗ existing non-git mirror path is not replaceable: $canon_path" (set_color normal)
                continue
            end
        else if test -L "$canon_path"
            printf '%s%s%s\n' (set_color yellow) "  ⚠ canonical is itself a symlink (dangling until its target exists)" (set_color normal)
        else
            echo "  ℹ canonical missing — makepkg will clone it here on the next build of $canon[3]"
        end

        # Point every other member at the canonical
        for m in $ranked[2..-1]
            set -l parts (string split '|' -- "$m")
            set -l twin_dir "$parts[3]"
            set -l twin_path "$twin_dir/$parts[2]"
            if test -L "$twin_path"
                set -l want (realpath -m "$canon_path" 2>/dev/null; or echo "$canon_path")
                set -l resolved (realpath -m "$twin_path" 2>/dev/null)
                if test "$resolved" = "$want"
                    printf '%s%s%s\n' (set_color green) "  ✓ linked: $twin_path" (set_color normal)
                    set n_ok (math $n_ok + 1)
                    continue
                end
                printf '%s%s%s\n' (set_color yellow) "  ↻ relinking $twin_path (was → $resolved)" (set_color normal)
                rm "$twin_path"
            else if valid_source_mirror "$twin_path"
                printf '%s%s%s\n' (set_color red) "  ☢ duplicate clone: $twin_path ("(du -sh "$twin_path" 2>/dev/null | cut -f1)")" (set_color normal)
                set -a deletions "$twin_path"
                set -a deletions "$twin_dir/src"
                set -a del_twins "$twin_dir|$parts[2]|$canon_path"
                continue
            else if test -d "$twin_path"
                set -l child (find "$twin_path" -mindepth 1 -maxdepth 1 \
                    -print -quit 2>/dev/null)
                if test -z "$child"
                    if not rmdir "$twin_path"
                        ui_error "cannot remove stale empty source path: $twin_path"
                        set n_error (math $n_error + 1)
                        continue
                    end
                else
                    printf '%s%s%s\n' (set_color red) "  ✗ existing non-git source path is not replaceable: $twin_path" (set_color normal)
                    continue
                end
            else
                echo "  ℹ creating symlink for not-yet-cloned $twin_path"
            end
            set -l relative_canon (realpath --relative-to="$twin_dir" "$canon_path" 2>/dev/null)
            if test -z "$relative_canon"; or not ln -sfn "$relative_canon" "$twin_path"
                ui_error "cannot link shared source path: $twin_path"
                set n_error (math $n_error + 1)
                continue
            end
            set n_fix (math $n_fix + 1)
        end
    end

    if test (count $deletions) -gt 0
        echo ""
        printf '%s%s%s\n' (set_color red) "☢ Dedup will delete "(count $deletions)" paths:" (set_color normal)
        for t in $deletions
            test -e "$t"; or continue
            printf '  %-8s %s\n' (du -sh "$t" 2>/dev/null | cut -f1) "$t"
        end
        echo "  (each clone's src/ working copy uses git alternates and must go too)"
        read -P "Proceed? [y/N] " -l answer
        if not string match -qi 'y*' -- "$answer"
            echo "Aborted — deletions skipped, other fixes already applied."
            return 0
        end
        for t in $deletions
            if not rm -rf -- "$t"
                ui_error "failed to delete duplicate source: $t"
                set n_error (math $n_error + 1)
            end
        end
        for dt in $del_twins
            set -l dp (string split '|' -- "$dt")
            set -l relative_canon (realpath --relative-to="$dp[1]" "$dp[3]" 2>/dev/null)
            if test -z "$relative_canon"; or not ln -sfn "$relative_canon" "$dp[1]/$dp[2]"
                ui_error "cannot restore shared source link: $dp[1]/$dp[2]"
                set n_error (math $n_error + 1)
            else
                set n_fix (math $n_fix + 1)
            end
        end
        printf '%s%s%s\n' (set_color green) "✓ duplicates removed — twins now share the canonical mirrors." (set_color normal)
    end

    echo ""
    echo "Shared-mirror scan done: $n_ok verified link(s), $n_fix change(s) applied."
    if test "$n_error" -gt 0
        echo "Shared-mirror scan encountered $n_error error(s)."
        return 1
    end
end

# Same-version sanity check for ONE archive: print (status 0) the installed
# version when installing it would be a no-op — its exact version is already
# installed AND that install is not older than the archive. Status 1 means
# "install": no installed entry, a version mismatch, a stale install date
# (a same-version rebuild whose payload never reached the system), or ANY
# doubt — a failed query, a missing field, an unparseable date. Doubt must
# install, never skip (2026-09-25). The queries are read-only: -Qp/-Qi take
# no db lock and need no sudo, so lanes may run them while another lane holds
# the -U mutex, and every failure path is caught by the value checks below
# even if the exit status were lost.
function install_skip_reason -a archive
    # Built name+version straight from pacman's own read of the archive — no
    # filename or PKGBUILD parsing, so epochs and split outputs arrive in the
    # same canonical form pacman will compare.
    set -l probe (pacman -Qp -- "$archive" 2>/dev/null)
    if test $status -ne 0; or test (count $probe) -ne 1
        return 1
    end
    set -l fields (string split -m1 ' ' -- $probe)
    if test (count $fields) -ne 2; or test -z "$fields[1]"; or test -z "$fields[2]"
        return 1
    end
    set -l built_version "$fields[2]"
    # Installed version + install date in one query. LANG=C pins the field
    # layout so the Install Date below is the C-locale text `date -d` parses.
    set -l info (LANG=C pacman -Qi -- "$fields[1]" 2>/dev/null)
    if test $status -ne 0; or test (count $info) -eq 0
        return 1
    end
    set -l installed_version ""
    set -l install_date ""
    for line in $info
        if string match -qr -- '^[[:space:]]*Version[[:space:]]*:' "$line"
            set installed_version (string replace -r -- '^[[:space:]]*Version[[:space:]]*:[[:space:]]*' '' "$line")
        else if string match -qr -- '^[[:space:]]*Install Date[[:space:]]*:' "$line"
            set install_date (string replace -r -- '^[[:space:]]*Install Date[[:space:]]*:[[:space:]]*' '' "$line")
        end
    end
    if test -z "$installed_version"; or test "$installed_version" != "$built_version"
        return 1
    end
    if test -z "$install_date"
        return 1
    end
    set -l installed_epoch (date -d "$install_date" +%s 2>/dev/null)
    if test $status -ne 0; or test -z "$installed_epoch"
        return 1
    end
    set -l archive_mtime (stat -c %Y -- "$archive" 2>/dev/null)
    if test $status -ne 0; or test -z "$archive_mtime"
        return 1
    end
    # Freshness guard: a same-version rebuild whose archive is NEWER than the
    # install must still be installed — version equality alone would skip it.
    if test "$installed_epoch" -lt "$archive_mtime"
        return 1
    end
    printf '%s\n' "$installed_version"
    return 0
end

# ─── Install decision plan & one executor ────────────────────────────────────
# ONE install pipeline: the decision half (install_plan) computes the
# transaction plan ONCE and SILENTLY — which archives to install, which to
# skip and why, or which refusal stops the whole thing — and one executor
# (install_execute) renders that plan and runs the single pacman transaction.
# Both entries are thin wrappers over the pair: -i (install_pkgs_now, checked
# mode) and -ia (install_all, FORCE mode — deliberately no same-version skip).
# The hidden --install-decide fixture seam prints the plan verbatim. Decisions
# never render, so "what would happen" (the seam) and "what happened" (the
# executor) cannot drift apart — the interface IS the test surface.
#
# Plan rows (fields space-separated; a path containing a space would truncate
# its row, which still decides correctly — no such path exists here):
#   install <archive>                   → run pacman -U for it
#   skip <archive> <installed-version>  → exact version, installed fresher
#   refuse empty-list                   → nothing to install (checked mode)
#   noop empty-list                     → nothing to do (force mode: mirrors -ia)
#   refuse pgo-*                        → see pgo_payload_refusals
# A refusal row aborts the whole transaction; skip and install rows may mix.
function install_plan -a mode
    set -l archives $argv[2..-1]
    if test (count $archives) -eq 0
        # An empty list is NOT success on the -i path. It means discovery
        # found no archive for the current evaluated pkgver-pkgrel, or could
        # not establish one; installing nothing leaves later packages
        # compiling against the old system version.
        # tests/install-archive-guard.sh pins both halves.
        if test "$mode" = force
            echo 'noop empty-list'
            return 0
        end
        echo 'refuse empty-list'
        return 1
    end
    # Never plan a PGO phase-1 payload: libgcov would recreate its build tree
    # on every run, and under -i every later package would build against it.
    set -l pgo_rows (pgo_payload_refusals $archives)
    if test $status -ne 0
        printf '%s\n' $pgo_rows
        return 1
    end
    if test "$mode" = force
        # -fi / -ia: the same-version sanity check is bypassed ENTIRELY —
        # install_skip_reason is never even consulted, so there is no second
        # implementation of the skip decision to drift.
        for archive in $archives
            echo "install $archive"
        end
        return 0
    end
    # Same-version sanity check (2026-09-25): drop every archive whose exact
    # version is already installed with an install date not older than the
    # archive; if nothing is left, there is no transaction to run. Doubt
    # installs: a failed query keeps the archive in the set, so the
    # conservative direction is always pacman -U, never silence.
    # tests/install-archive-guard.sh pins both directions plus the force
    # bypass.
    for archive in $archives
        set -l iver (install_skip_reason "$archive")
        if test $status -eq 0
            echo "skip $archive $iver"
        else
            echo "install $archive"
        end
    end
    return 0
end

# install_emit SINK LOG_FILE LEVEL TEXT — the ONE rendering seam of the
# install pipeline. quiet: append to the transcript (lane children must never
# write to the terminal — the dispatcher owns all progress rendering). loud:
# print with the usual icon. LEVEL is error or info.
function install_emit -a sink log_file level text
    if test "$sink" = quiet
        switch $level
            case error
                printf '%s %s\n' "$_UI_ICON_ERROR" "$text" >>"$log_file"
            case '*'
                printf '%s %s\n' "$_UI_ICON_INFO" "$text" >>"$log_file"
        end
    else
        switch $level
            case error
                ui_error "$text"
            case '*'
                ui_info "$text"
        end
    end
end

# install_execute LOG_FILE SINK N_EXTRA EXTRA... PLAN_ROW... — the ONE
# executor: renders the plan (refusals abort before anything else, then the
# skip note) and runs the single pacman transaction for its install set.
# SINK is quiet | loud. The N_EXTRA argv after it are forwarded to pacman
# verbatim (-ia's `--overwrite …`); everything past them is plan rows.
# One pacman transaction per call. --ask 4 auto-accepts removal of conflicting
# (e.g. stock) packages — the stock→-git swap prompt — so a run never blocks on
# a prompt. Returns 1 on refusal or transaction failure so callers abort the
# chain: a package that failed to install means every later package would
# compile against the WRONG system state (the 2026-09-06 rust-git/minimal-
# llvm-git incident class).
function install_execute -a log_file sink n_extra
    set -l rest $argv[4..-1]
    set -l extra
    set -l rows
    if test "$n_extra" -gt 0
        set extra $rest[1..$n_extra]
        set rows $rest[(math $n_extra + 1)..-1]
    else
        set rows $rest
    end
    # The transcript must be writable BEFORE pacman runs: appending rule-11
    # forensics into an unopenable log would swallow the record of exactly the
    # failure this function exists to make loud. Refusing here aborts the run.
    # (Straight to the terminal: the transcript is the thing that is broken.)
    if not ensure_log_writable "$log_file"
        ui_error "install transcript not writable: $log_file — refusing to install without a record"
        return 1
    end
    set -l installs
    set -l skips
    set -l skip_version ""
    set -l refusals
    for row in $rows
        set -l fields (string split ' ' -- "$row")
        switch $fields[1]
            case install
                set -a installs $fields[2]
            case skip
                set -a skips $fields[2]
                set skip_version $fields[3]
            case noop
                # force mode with nothing to do — no message, no transaction.
            case '*'
                set -a refusals $row
        end
    end
    if test (count $refusals) -gt 0
        for row in $refusals
            set -l fields (string split ' ' -- "$row")
            switch $fields[2]
                case empty-list
                    if test "$sink" = quiet
                        printf '%s Install requested but no built package archive matched the current pkgver-pkgrel — refusing to report success\n' "$_UI_ICON_ERROR" >>"$log_file"
                    else
                        ui_error "install requested but no built package archive was found for the current pkgver-pkgrel"
                    end
                case pgo-temp
                    install_emit "$sink" "$log_file" error "cannot create a temp dir to verify "(basename "$fields[3]")
                case pgo-unreadable
                    install_emit "$sink" "$log_file" error "refusing to install "(basename "$fields[3]")": its payload could not be read (tar rc=$fields[4], $fields[5] files), so PGO instrumentation cannot be ruled out"
                case pgo-hit
                    install_emit "$sink" "$log_file" error (basename "$fields[3]")": profile-instrumented payload — "$fields[4]
                case pgo-instrumented
                    install_emit "$sink" "$log_file" error "refusing to install "(basename "$fields[3]")": a phase-1 PGO binary is packaged, so libgcov would recreate its build tree on every run"
                    install_emit "$sink" "$log_file" error "rebuild the recipe so phase 2 really replaces the profiled flags (docs/build-guide.md: PGO)"
                case '*'
                    install_emit "$sink" "$log_file" error "unrecognized install-plan refusal: $row"
            end
        end
        return 1
    end
    if test (count $skips) -gt 0
        install_emit "$sink" "$log_file" info (count $skips)" of "(math (count $skips) + (count $installs))" package(s) already installed at $skip_version — skipping their install"
    end
    if test (count $installs) -eq 0
        return 0
    end
    # Install: root mode runs pacman directly (no timestamp to expire);
    # unprivileged mode escalates with `sudo -n` — the builder NEVER prompts
    # (a lane has no tty, and an unattended run must fail fast, not hang).
    # Explicit if/else: fish REJECTS `$pre pacman` when $pre expands to
    # nothing ("expanded command was empty") — no empty-prefix tricks.
    set -l cmd
    if test "$_ROOT_MODE" = "1"
        set cmd pacman
    else
        set cmd sudo -n pacman
    end
    set -l irc 1
    if test "$sink" = quiet
        # Lane children must never write to the terminal; the dispatcher owns
        # all progress rendering. Keep pacman hooks and transactions in the
        # package log instead of tailing a line to stdout.
        run_pacman_locked "$log_file" $cmd -U --noconfirm --ask 4 $extra $installs >>"$log_file" 2>&1
        set irc $status
    else
        echo "  Installing: "(string join ' ' $installs)
        run_pacman_locked "$log_file" $cmd -U --noconfirm --ask 4 $extra $installs 2>&1 | tee -a "$log_file" | tail -3
        set irc $pipestatus[1]
    end
    if test $irc -ne 0
        if test "$sink" = quiet
            printf '%s Install failed (rc=%s) — stopping: later packages would build against the wrong system state\n' "$_UI_ICON_ERROR" "$irc" >>"$log_file"
            printf '  NOTE: with -i the BUILD may still have succeeded (archive exists); install later with -ia or resume with -s -i\n' >>"$log_file"
        else
            ui_error "Install failed (rc=$irc)"
        end
        return 1
    end
    return 0
end

# install_pkgs_now LOG_FILE QUIET_FLAG FORCE_FLAG ARCHIVE... — the -i entry:
# one package's install inside a build chain. QUIET_FLAG 1 = lane mode
# (transcript only, no terminal); FORCE_FLAG 1 = -fi (plan in force mode).
# The mode/sink ride as ARGUMENTS, not globals — the pipeline reads nothing
# hidden. The plan is computed once here and consumed by the executor.
function install_pkgs_now -a log_file quiet_flag force_install_flag
    set -l pkgs $argv[4..-1]
    set -l mode checked
    if test "$force_install_flag" = "1"
        set mode force
    end
    set -l sink loud
    if test "$quiet_flag" = "1"
        set sink quiet
    end
    set -l plan (install_plan $mode $pkgs)
    install_execute "$log_file" $sink 0 $plan
end

function sanitize_log_stream
    # Remove ANSI CSI sequences and terminal controls before log text reaches
    # either the dashboard or the interactive failure replay.
    sed -E 's#\x1b\[[0-9;?]*[[:alpha:]]##g; s#\r##g; s#\t#    #g; s#[[:cntrl:]]##g'
end

function dashboard_tail_rows -a pkg
    if test -z "$pkg"
        printf '%s\n' "  $_UI_ICON_INFO idle" "  $_UI_ICON_INFO idle" "  $_UI_ICON_INFO idle"
        return 0
    end

    set -l log_file (package_log_file "$pkg")
    set -l lines (tail -n 3 "$log_file" 2>/dev/null | sanitize_log_stream)
    for i in (seq 3)
        set -l line ""
        if test $i -le (count $lines)
            set line "$lines[$i]"
        end
        if test -n "$line"
            printf '  > %s\n' "$line"
        else
            printf '%s\n' "  $_UI_ICON_INFO no output yet"
        end
    end
end

function print_log_tail -a log_file
    # Build tools may leave carriage-return progress lines in a log even when
    # their output is redirected. Never replay those controls into the tty.
    tail -n 15 "$log_file" 2>/dev/null | sanitize_log_stream | sed 's/^/    /'
end

# ─── Package reference resolution and name hints ─────────────────────────────
# Accepted reference forms, in priority order:
#   1. recipe ID             mesa-git
#   2. recipe path           packages/git/mesa-git   (or ./packages/…)
#   3. case-variant ID       MESA-GIT
#   4. pacman package name   zen-browser             (including a split output)
# Tiers 3-4 are exact lookups, never guesses: recipe IDs are lower-case and the
# .SRCINFO name index is collision-free (no name is shared by two recipes), so
# neither can select the wrong recipe, and _ref_form_note announces every
# substitution. A typo is deliberately NOT auto-corrected — a wrong guess would
# build the wrong package and its whole consumer closure — it is reported with
# _report_unknown_ref.

# "name|recipe-id" for every pacman package name the recipes build, read from
# the committed .SRCINFO files. Committed metadata means no PKGBUILD
# evaluation: `makepkg --printsrcinfo` has already expanded every variable, and
# tests/srcinfo-freshness.sh keeps it in step with the recipes. A recipe without
# .SRCINFO (the synthetic fixture workspaces) contributes nothing — fewer hints,
# never an error.
function _pkgname_index
    if not set -q _PKGNAME_INDEX
        set -g _PKGNAME_INDEX
        for entry in $_PACKAGE_MAP
            set -l fields (string split '|' -- "$entry")
            set -l srcinfo "$SCRIPT_DIR/$fields[2]/.SRCINFO"
            test -f "$srcinfo"; or continue
            for name in (sed -n 's/^pkgname = //p' "$srcinfo" 2>/dev/null)
                set -a _PKGNAME_INDEX "$name|$fields[1]"
            end
        end
    end
    test (count $_PKGNAME_INDEX) -gt 0; and printf '%s\n' $_PKGNAME_INDEX
end

# Recipe ID that builds a given pacman package name, or nothing.
function _pkgname_owner -a name
    for entry in (_pkgname_index)
        set -l fields (string split '|' -- "$entry")
        if test "$fields[1]" = "$name"
            echo "$fields[2]"
            return 0
        end
    end
    return 1
end

# Announce a substitution canonicalize_pkg_ref made, so a reference never
# silently means something else. An already-canonical reference (ID) needs no
# note, and neither does a recipe path: the caller typed the recipe itself.
function _ref_form_note -a given resolved
    test "$given" = "$resolved"; and return 0
    if test (string lower -- "$given") = (string lower -- "$resolved")
        ui_info "matched recipe '$resolved' — recipe IDs are case-sensitive"
        return 0
    end
    set -l owner (_pkgname_owner "$given")
    test -n "$owner"; and ui_info "pacman package '$given' is built by recipe '$owner'"
end

# Candidate lines within `max` edits of TOKEN on stdin, as "distance line",
# nearest first. awk keeps this to one process for the whole candidate list; the
# same sweep in fish costs ~0.4s, which a hint is not worth.
function _nearest_lines -a token max
    awk -v tok="$token" -v max="$max" '
        function dist(a, b,   la, lb, i, j, prev, cur, ca, cb, cost, best) {
            la = length(a); lb = length(b)
            for (j = 0; j <= lb; j++) prev[j] = j
            for (i = 1; i <= la; i++) {
                cur[0] = i
                ca = substr(a, i, 1)
                for (j = 1; j <= lb; j++) {
                    cb = substr(b, j, 1)
                    cost = (ca == cb) ? 0 : 1
                    best = prev[j] + 1
                    if (cur[j-1] + 1 < best) best = cur[j-1] + 1
                    if (prev[j-1] + cost < best) best = prev[j-1] + cost
                    cur[j] = best
                }
                for (j = 0; j <= lb; j++) prev[j] = cur[j]
            }
            return prev[lb]
        }
        { d = dist(tok, $0); if (d <= max) print d " " $0 }'
end

# Up to three candidate recipe IDs for an unresolvable reference, as
# "id reason" lines, most specific first.
function _suggest_refs -a token
    set -l out
    set -l lowered (string lower -- "$token")

    # 1. exact pacman package name
    for entry in (_pkgname_index)
        set -l fields (string split '|' -- "$entry")
        test "$fields[1]" = "$token"; and set -a out "$fields[2] pkgname"
    end

    # 2. case variant of a recipe ID
    contains "$lowered" $_PACKAGE_IDS; and set -a out "$lowered case"

    # 3. substring, either direction. Literal matching in awk, so a token
    #    containing glob characters cannot turn into a pattern.
    if test (count $out) -lt 3
        for id in (printf '%s\n' $_PACKAGE_IDS | \
            awk -v tok="$lowered" 'index($0, tok) > 0 || index(tok, $0) > 0')
            test (count $out) -ge 3; and break
            set -a out "$id substring"
        end
    end

    # 4. near miss (transposition, one wrong character)
    if test (count $out) -lt 3
        for id in (printf '%s\n' $_PACKAGE_IDS | _nearest_lines "$lowered" 2 \
            | sort -n | cut -d' ' -f2-)
            test (count $out) -ge 3; and break
            set -a out "$id typo"
        end
    end

    set -l seen
    for line in $out
        set -l id (string split ' ' -- "$line")[1]
        contains "$id" $seen; and continue
        set -a seen "$id"
        echo "$line"
    end
end

# Nearest known long option to a mistyped flag, or nothing. Only long options
# are hinted — a one-letter flag is a different flag rather than a typo, and the
# usage dump that follows lists them all. No first-character prefilter: with 19
# options, distance <= 2 yields a single candidate for every typo measured and a
# prefilter only cost true positives (`--xanels` -> `--lanes`).
function _suggest_option -a given
    string match -qr '^--' -- "$given"; or return 0
    set -l options --install --forceinstall --clean --skip --no-sync --lanes --jobs --intensity \
        --allow-broken-rustc --no-deps --dry-run --list --group --help --topology \
        --installall --cleanup --nuclear --link-sources --audit
    set -l hit (printf '%s\n' $options | _nearest_lines "$given" 2 \
        | sort -n | head -1 | cut -d' ' -f2-)
    test -n "$hit"; and echo "  Did you mean '$hit'?"
end

# The single place an unresolvable package reference is reported, so the two
# selection paths (group branch and package-only branch) cannot drift apart.
function _report_unknown_ref -a token
    ui_error "package recipe not found: '$token'"
    set -l hints (_suggest_refs "$token")
    if test (count $hints) -gt 0
        echo "  Did you mean:"
        for line in $hints
            set -l parts (string split ' ' -- "$line")
            switch $parts[2]
                case pkgname
                    echo "    $parts[1]  (pacman package '$token' is built by this recipe)"
                case case
                    echo "    $parts[1]  (recipe IDs are case-sensitive)"
                case substring
                    echo "    $parts[1]  (contains '$token')"
                case typo
                    echo "    $parts[1]  (closest match)"
            end
        end
    end
    echo "  Run 'build-all.fish -l' to list all "(count $_PACKAGE_IDS)" packages (or '-l -g GROUP')."
end

# Normalize package references to package IDs. IDs, relative recipe paths,
# case-variant IDs and pacman package names are accepted so resumed commands
# remain easy to translate.
function canonicalize_pkg_ref -a pkg
    if contains "$pkg" $_PACKAGE_IDS
        echo "$pkg"
        return 0
    end
    for entry in $_PACKAGE_MAP
        set -l fields (string split '|' -- "$entry")
        if test "$pkg" = "$fields[2]"
            echo "$fields[1]"
            return 0
        end
    end
    if test -d "$SCRIPT_DIR/$pkg"
        set -l id (package_id_for_path "$SCRIPT_DIR/$pkg")
        if test -n "$id"
            echo "$id"
            return 0
        end
    end
    # Tiers 3-4: exact lookups against the committed index (see the header).
    set -l lowered (string lower -- "$pkg")
    if test "$lowered" != "$pkg"; and contains "$lowered" $_PACKAGE_IDS
        echo "$lowered"
        return 0
    end
    set -l owner (_pkgname_owner "$pkg")
    if test -n "$owner"
        echo "$owner"
        return 0
    end
    echo "$pkg"
end

# GCC LTO bytecode is tied to the compiler build that emitted it. Keep one
# identity per recipe in builder state so only affected incremental trees need
# cleaning after a toolchain upgrade.
function package_toolchain_state_matches -a package_id pkg_path gcc_identity
    set -l state_file "$_STATE_DIR/toolchains/$package_id"
    if not test -f "$state_file"
        return 1
    end
    set -l saved (cat "$state_file" 2>/dev/null)
    if test (count $saved) -ne 2
        return 1
    end
    test "$saved[1]" = "$pkg_path" -a "$saved[2]" = "$gcc_identity"
end

function record_package_toolchain -a package_id pkg_path gcc_identity
    set -l state_dir "$_STATE_DIR/toolchains"
    set -l state_file "$state_dir/$package_id"
    set -l temporary "$state_file.tmp.$fish_pid"
    set -l run_as env
    if test "$_ROOT_MODE" = "1"
        set run_as sudo -u "$_BUILD_USER" env HOME=$_BUILD_HOME
    end
    if not $run_as mkdir -p "$state_dir"
        ui_error "$package_id: cannot create compiler state directory: $state_dir"
        return 1
    end
    if not $run_as sh -c 'printf "%s\n%s\n" "$1" "$2" >"$3" && mv -f -- "$3" "$4"' \
        sh "$pkg_path" "$gcc_identity" "$temporary" "$state_file"
        $run_as rm -f -- "$temporary" 2>/dev/null
        ui_error "$package_id: cannot record GCC build identity: $state_file"
        return 1
    end
    return 0
end

# ─── Build a single package ──────────────────────────────────────────────────
function build_package -a package_id install_flag clean_flag skip_flag no_sync_flag quiet_flag force_install_flag
    # quiet_flag=1: background lane mode — no human echoes; everything goes to
    # the per-package log; the parent dispatcher renders lane state.
    set -g _BUILD_QUIET (test "$quiet_flag" = "1"; and echo 1; or echo 0)
    # Why the current invocation defers, when it names one; reset per package
    # so a lane process can never leak a previous run's reason onto the wire.
    set -g _DEFER_REASON ""
    # -fi/--forceinstall now rides as the FORCE_FLAG argument to
    # install_pkgs_now alongside this one — the install pipeline reads its
    # mode/sink from arguments, never from a hidden global.
    # Absolute path consolidation: never depend on the ambient cwd
    set -l pkg_path (package_path "$package_id" | string collect)
    set -l pkg_name "$package_id"

    if test -z "$pkg_path"
        ui_error "package ID does not resolve: $package_id"
        return 1
    end

    if not test -f "$pkg_path/PKGBUILD"
        ui_error "PKGBUILD not found: $pkg_path/PKGBUILD"
        return 1
    end

    set -l gcc_identity "gcc unavailable"
    if type -q gcc
        set -l gcc_version (env LC_ALL=C gcc --version 2>/dev/null)
        set -l gcc_status $status
        if test $gcc_status -ne 0; or test (count $gcc_version) -eq 0; or test -z "$gcc_version[1]"
            ui_error "$pkg_name: could not determine the GCC build identity"
            return 1
        end
        set gcc_identity "$gcc_version[1]"
    end
    set -l toolchain_mismatch 0
    if not package_toolchain_state_matches "$package_id" "$pkg_path" "$gcc_identity"
        set toolchain_mismatch 1
    end

    # A drift clean deletes the archive and its VCS baseline. Resolve a
    # potentially skippable archive first so an unreachable ref still refuses
    # before makepkg rather than being hidden by that automatic clean.
    if test "$toolchain_mismatch" = "1"; and test "$clean_flag" != "1"; and test "$skip_flag" = "1"
        set -l candidate (find "$pkg_path" -maxdepth 1 -name '*.pkg.tar.zst' \
            -printf '%T@\t%p\n' 2>/dev/null | sort -rn | head -1 | cut -f2-)
        if test -n "$candidate"
            set -l pkg_time (stat -c %Y "$pkg_path/PKGBUILD" 2>/dev/null)
            set -l built_time (stat -c %Y "$candidate" 2>/dev/null)
            if test -n "$pkg_time" -a -n "$built_time" -a "$built_time" -ge "$pkg_time"
                vcs_archive_is_current "$pkg_path" "$candidate"
                set -l freshness_status $status
                if test $freshness_status -eq 2
                    # rc 2 = freshness cannot be established (transport
                    # retries exhausted inside the query). Owner semantics
                    # (2026-10-02): -s may skip ONLY on verified-unchanged.
                    # Unverifiable parks the recipe ONLY when its consumer
                    # chain can absorb the wait (few or no waiters); else it
                    # falls back to a normal build attempt. Never fail.
                    ui_error "$pkg_name: --skip cannot verify upstream VCS freshness: $_VCS_REVISION_ERROR"
                    switch (unverifiable_defer_plan "$package_id")
                        case defer
                            set -g _DEFER_REASON upstream-unverified
                            ui_error "$pkg_name: consumer chain can absorb the wait — parking this recipe (deferred)"
                            echo "  Nothing was built or installed; dependents wait (waits-on-deferred)."
                            return $lane_outcome_defer
                        case '*'
                            ui_error "$pkg_name: consumers cannot wait — falling back to a normal build attempt"
                    end
                end
            end
        end
    end

    # An unknown or changed compiler invalidates incremental objects. Use the
    # same clean path as -c before considering an otherwise-current -s archive.
    if test "$clean_flag" = "1" -o "$toolchain_mismatch" = "1"
        if test "$_BUILD_QUIET" != "1"
            if test "$toolchain_mismatch" = "1"
                ui_info "$pkg_name: GCC build identity missing or changed; cleaning cached build artifacts"
            else
                ui_info "Cleaning build artifacts for $pkg_name..."
            end
        end
        if not command rm -rf -- "$pkg_path/src" "$pkg_path/pkg" "$pkg_path/build"
            ui_error "failed to clean build artifacts for $pkg_name"
            return 1
        end
        if not find "$pkg_path" -maxdepth 1 \
            \( -name '*.pkg.tar.zst' -o -name '*.pkg.tar.zst.gsa-vcs-revisions' \) \
            -delete 2>/dev/null
            ui_error "failed to remove old package archives for $pkg_name"
            return 1
        end
    end

    # Skip if already built (only when -s flag is set)
    if test "$skip_flag" = "1"
        # find with -printf: newest archive by mtime (fish globs would FATAL on
        # "no matches" for packages that have no built archive yet)
        set -l latest_pkg (find "$pkg_path" -maxdepth 1 -name '*.pkg.tar.zst' -printf '%T@\t%p\n' 2>/dev/null | sort -rn | head -1 | cut -f2-)
        if test -n "$latest_pkg"
            set -l pkg_time (stat -c %Y "$pkg_path/PKGBUILD" 2>/dev/null)
            set -l built_time (stat -c %Y "$latest_pkg" 2>/dev/null)
            if test -n "$pkg_time" -a -n "$built_time" -a "$built_time" -ge "$pkg_time"
                vcs_archive_is_current "$pkg_path" "$latest_pkg"
                set -l freshness_status $status
                if test $freshness_status -eq 2
                    # Same contract as the toolchain pre-check above (owner
                    # semantics 2026-10-02): park when the consumer chain
                    # can absorb the wait, else fall back to a normal build.
                    ui_error "$pkg_name: --skip cannot verify upstream VCS freshness: $_VCS_REVISION_ERROR"
                    switch (unverifiable_defer_plan "$package_id")
                        case defer
                            set -g _DEFER_REASON upstream-unverified
                            ui_error "$pkg_name: consumer chain can absorb the wait — parking this recipe (deferred)"
                            echo "  Nothing was built or installed; dependents wait (waits-on-deferred)."
                            return $lane_outcome_defer
                        case '*'
                            ui_error "$pkg_name: consumers cannot wait — falling back to a normal build attempt"
                    end
                end
                if test $freshness_status -eq 0
                    if test "$_BUILD_QUIET" != "1"
                        ui_info "$pkg_name: already built ($(basename $latest_pkg))"
                    end
                    # -s + -i: the skip path installs too — topo order must
                    # hold for already-built packages just the same.
                    # ($log_file isn't defined yet — use the canonical path.)
                    if test "$install_flag" = "1"
                        install_pkgs_now (package_log_file "$package_id") 1 $force_install_flag (list_split_pkgs "$pkg_path"); or return 1
                    end
                    return 0
                end
                if test "$_BUILD_QUIET" != "1"
                    if test $freshness_status -eq 3
                        ui_info "$pkg_name: $_VCS_REVISION_ERROR; rebuilding once to record a baseline"
                    else
                        ui_info "$pkg_name: upstream VCS ref moved; rebuilding"
                    end
                end
            end
        end
    end

    if not ensure_state_dirs
        return 1
    end
    set -l log_file (package_log_file "$package_id")
    # The log is opened FRESH per attempt by the dispatcher (it truncates
    # before spawning this lane) and every writer appends — including this
    # lane's own stdout/stderr (O_APPEND). Never truncate here again: this
    # point sits AFTER the skip/freshness decision messages, and a mid-stream
    # truncate both destroys them and races the append-only writers (2026-10-02
    # T4 finding). Provider errors and checksum decisions all append below.
    if not ensure_log_writable "$log_file"
        ui_error "cannot write build log: $log_file"
        return 1
    end
    if test "$toolchain_mismatch" = "1"
        printf 'GCC build identity missing or changed; cached build artifacts were cleaned before this build.\nGCC: %s\n' \
            "$gcc_identity" >>"$log_file"
    end

    # An explicit topology opt-in selects nvchecker; every other stable recipe
    # keeps the existing Arch repository behavior.
    #
    # In the default Arch path, what makes committed sums stale is not the
    # version number but a moved *source*: 26 of the 28 stable recipes pin a
    # literal version inside their source=() URLs, so a pkgver rewrite leaves
    # them fetching exactly what they fetched before and their sums still
    # verify. Only linux-api-headers and linux-firmware spell the version into a
    # URL. Diffing the array around the rewrite is therefore the precise signal,
    # and treating every pkgver bump as stale would refuse builds whose sums
    # were never in question.
    set -l sources_before (pkgbuild_array "$pkg_path" source)
    set -l external_sync 0
    if test "$no_sync_flag" != "1"
        set -l version_provider (package_version_sync_provider "$package_id")
        if test "$version_provider" = nvchecker
            sync_nvchecker_version "$package_id" "$pkg_path"
            set -l sync_status $status
            switch $sync_status
                case 0 1 3
                    # Source changes and checksum anchoring are handled by the
                    # opted-in provider path as one rollback boundary.
                case $lane_outcome_defer
                    return $lane_outcome_defer
                case '*'
                    ui_error "failed to synchronize upstream metadata for $pkg_name"
                    return 1
            end
            set external_sync 1
        else
            sync_stable_version "$pkg_path"
            switch $status
                case 0 1 3
                    # 1 = pkgver moved, 3 = only pkgrel/epoch moved; the source
                    # diff below decides whether the sums need re-anchoring.
                case '*'
                    ui_error "failed to synchronize stable metadata for $pkg_name"
                    return 1
            end
        end
    end
    set -l sources_after (pkgbuild_array "$pkg_path" source)
    set -l moved_sources
    set -l source_count (count $sources_after)
    if test (count $sources_before) -gt $source_count
        set source_count (count $sources_before)
    end
    for i in (seq $source_count)
        if test "$sources_before[$i]" != "$sources_after[$i]"
            set -a moved_sources $sources_after[$i]
        end
    end
    set -l stale_sums 0
    if test (count $moved_sources) -gt 0; and test $external_sync -eq 0
        set stale_sums 1
    end

    if test "$_BUILD_QUIET" != "1"
        ui_heading "Building: $pkg_name"
    end

    # Build
    set -l makepkg_args -sf --noconfirm
    if test $stale_sums -eq 1
        # The default Arch sync moved a source URL, so the committed sums now
        # describe the previous version. They are re-anchored to the official
        # Arch checksums and the fetched sources are verified against those —
        # not skipped (which builds unverified sources), and for an entry Arch
        # publishes, never re-hashed from the fetch alone either (an entry Arch
        # publishes NO checksum for is refreshed at sync time and recorded as
        # fetch-only — anchor_sums_from_official's header carries the trust
        # model).
        #
        # Neither the anchoring nor a refusal may be silent: build_package is
        # only ever called quiet (every lane redirects its stdout/stderr into
        # the per-package log), so that log is the only record a person can
        # inspect afterwards.
        anchor_sums_from_official "$pkg_path" $moved_sources
        switch $status
            case 0 1
                # Anchored (0) or nothing to anchor (1) — build proceeds.
            case 4
                # A source disagrees with Arch's published checksum: an
                # integrity signal, treated like a failed build — it stops the
                # dispatch. Parking it would keep building the rest of the run
                # over a possible tamper signal.
                return 1
            case '*'
                # Anchoring is impossible right now (2: fetch/tool/refresh
                # failure, recipe restored; 3: no official document at our
                # version, recipe untouched). Defer instead of draining the
                # dispatch: the lane result protocol is unchanged — the
                # lane_outcome_defer value rides in the same rc field — and
                # the dispatcher parks the recipe with a named marker while
                # the rest continues.
                return $lane_outcome_defer
        end
    end

    # Full redirect to the log (2026-09-07): 'tee' to a lagging terminal
    # backpressures compiler output; file-only logging is cheaper and keeps
    # the terminal readable. Failure tails are printed by the caller.
    set -l archive_snapshot_before (package_archive_snapshot "$pkg_path")
    set -l start_s (date +%s)
    if test "$_BUILD_QUIET" != "1"
        echo "  makepkg $makepkg_args | log: $log_file"
    end
    if not pushd "$pkg_path" >/dev/null
        ui_error "cannot enter package directory: $pkg_path"
        return 1
    end
    if test "$_ROOT_MODE" = "1"
        # Root supervises, the invoking user builds. HOME is pinned to the
        # user's home so tool caches (~/.ccache, ~/.cargo, ~/.cache/go-build)
        # stay in THEIR home — nothing lands in /root. MAKEFLAGS/NINJAFLAGS
        # pass through explicitly (sudo strips the environment by default).
        set -l env_prefix env HOME=$_BUILD_HOME
        if test -n "$MAKEFLAGS"
            set -a env_prefix MAKEFLAGS=$MAKEFLAGS
        end
        if test -n "$NINJAFLAGS"
            set -a env_prefix NINJAFLAGS=$NINJAFLAGS
        end
        if set -q GSA_BUILD_JOBS; and test -n "$GSA_BUILD_JOBS"
            set -a env_prefix GSA_BUILD_JOBS=$GSA_BUILD_JOBS
        end
        if set -q GSA_TARGET_CPU; and test -n "$GSA_TARGET_CPU"
            set -a env_prefix GSA_TARGET_CPU=$GSA_TARGET_CPU
        end
        # sudo strips the environment; pass the pacman shim explicitly so
        # root-mode makepkg dep installs share the builder mutex too
        # (lane_job exports PACMAN; see ensure_pacman_shim).
        if set -q PACMAN; and test -n "$PACMAN"
            set -a env_prefix PACMAN=$PACMAN
        end
        sudo -u "$_BUILD_USER" $env_prefix makepkg $makepkg_args >>"$log_file" 2>&1
    else
        makepkg $makepkg_args >>"$log_file" 2>&1
    end
    set -l rc $status
    set -l archive_snapshot_after (package_archive_snapshot "$pkg_path")
    set -l changed_archives
    set -l archive_revision_error ""
    for after_row in $archive_snapshot_after
        set -l after_fields (string split \t -- "$after_row")
        if test (count $after_fields) -ne 3
            set archive_revision_error "cannot inspect package archive after building"
            continue
        end
        set -l old_mtime ""
        set -l old_size ""
        for before_row in $archive_snapshot_before
            set -l before_fields (string split \t -- "$before_row")
            if test (count $before_fields) -eq 3; and test "$before_fields[1]" = "$after_fields[1]"
                set old_mtime "$before_fields[2]"
                set old_size "$before_fields[3]"
                break
            end
        end
        if test -z "$old_mtime"; or test "$old_mtime" != "$after_fields[2]"; or test "$old_size" != "$after_fields[3]"
            set -a changed_archives "$after_fields[1]"
            if test -e "$after_fields[1].gsa-vcs-revisions"; \
                and not rm -f -- "$after_fields[1].gsa-vcs-revisions"
                set archive_revision_error "cannot invalidate the old VCS revision record for "(basename "$after_fields[1]")
            end
        end
    end
    if not popd >/dev/null
        ui_error "cannot restore working directory after building $pkg_name"
        return 1
    end
    set -l dur (math (date +%s) - $start_s)

    # Root mode: restore user ownership of everything this run touched in the
    # workspace (clean/sync ran as root; sed -i would leave root-owned
    # PKGBUILDs). Runs on BOTH success and failure — a failed build that
    # leaves root-owned src/build files poisons the retry with EACCES
    # (2026-09-08 gtk3-git: root-owned src/build/modules → meson OSError).
    if test "$_ROOT_MODE" = "1"
        if not chown -R "$_BUILD_USER": "$pkg_path" "$LOG_DIR" 2>/dev/null
            ui_error "failed to restore ownership after building $pkg_name"
            return 1
        end
    end

    if test -n "$archive_revision_error"
        ui_error "$pkg_name: $archive_revision_error"
        return 1
    end

    if test $rc -ne 0
        if test "$_BUILD_QUIET" != "1"
            ui_error "$pkg_name: BUILD FAILED (rc=$rc)"
            echo "  Log: $log_file"
            ui_warning "Last lines:"
            print_log_tail "$log_file"
        end
        return 1
    end

    for archive in $changed_archives
        if not record_vcs_archive_revisions "$pkg_path" "$archive"
            ui_error "$pkg_name: build succeeded but VCS revisions could not be recorded for "(basename "$archive")": $_VCS_REVISION_ERROR"
            return 1
        end
    end

    if not record_package_toolchain "$package_id" "$pkg_path" "$gcc_identity"
        ui_error "$pkg_name: build succeeded but its GCC build identity could not be recorded"
        return 1
    end

    if test "$_BUILD_QUIET" != "1"
        ui_success "$pkg_name: build succeeded ("(fmt_dur $dur)")"
    end

    # -i: install IMMEDIATELY, in topo order. A package must be installed
    # before its dependents compile, or they build/link against the old
    # system version (2026-09-06 rust-git vs minimal llvm-git incident).
    if test "$install_flag" = "1"
        if not install_pkgs_now "$log_file" 1 $force_install_flag (list_split_pkgs "$pkg_path")
            return 1
        end
    end

    return 0
end

# ─── Parallel build lanes ────────────────────────────────────────────────────
# run_lanes dispatches READY packages (all workspace deps already installed)
# to N background makepkg lanes. Rationale (2026-09-07): single-threaded
# final links leave cores idle; a second lane fills them with independent
# packages from the wide tail of the dependency graph.
#
# Concurrency design:
# - core-group packages are LTO/RAM monsters — they run SOLO with the full
#   core count, never paired with another build (RAM contention).
# - Non-solo lanes share a CPU/RAM-derived per-lane job limit.
# - pacman installs happen inside background jobs (no tty): the dispatcher
#   keeps the sudo timestamp warm with a `sudo -n -v` keepalive (escalation
#   never prompts), and a builder-owned flock serializes transactions before
#   pacman can contend on its database lock.
# - Lane supervisors use isolated sessions and redirect their complete
#   stdout/stderr stream to the package log; only the parent renders status.
# - Result protocol: each lane job writes "pkgdir rc seconds" to its result
#   file; the dispatcher polls those files every 0.5 s.
# - lanes=1 preserves the old sequential semantics exactly (strict topo order).

set -g _lane_sorted
set -g _lane_done
set -g _lane_started

function deps_of -a pkg
    for entry in $_DEPS
        set -l parts (string split ':' $entry -m 2)
        if test "$parts[1]" = "$pkg"
            if test (count $parts) -ge 2 -a -n "$parts[2]"
                string split ',' $parts[2]
            end
            return
        end
    end
end

# ─── Topology tags (the record's tags field) ─────────────────────────────────
# The vocabulary is closed and loader-validated: abi=must (batch anchor or
# mandatory member), abi=should (same-pass candidate) and app-cluster=<name>
# (members sharing the name render as ONE app-prompt toggle row), plus the
# version-sync=nvchecker provider opt-in. These helpers expose each tag only to
# its owning seam.
# package_abi_severity PKG → must | should | none
function package_abi_severity -a pkg
    for entry in $_TAGS
        set -l parts (string split '|' -- "$entry")
        test "$parts[1]" = "$pkg"; or continue
        set -l tags (string split ',' -- "$parts[2]")
        if contains abi=must $tags
            echo must
        else if contains abi=should $tags
            echo should
        else
            echo none
        end
        return
    end
    echo none
end

# package_version_sync_provider PKG → nvchecker | none.
# The topology tag is the opt-in; a recipe config alone does not select a
# version provider.
function package_version_sync_provider -a pkg
    for entry in $_TAGS
        set -l parts (string split '|' -- "$entry")
        test "$parts[1]" = "$pkg"; or continue
        for tag in (string split ',' -- "$parts[2]")
            if test "$tag" = version-sync=nvchecker
                echo nvchecker
                return
            end
        end
        echo none
        return
    end
    echo none
end

# package_app_cluster PKG → the record's app-cluster=<name> value, or nothing.
# Members sharing one name belong to one prompt row; the loader caps a record
# at one such tag, and only prompt_app_selection consumes this.
function package_app_cluster -a pkg
    for entry in $_TAGS
        set -l parts (string split '|' -- "$entry")
        test "$parts[1]" = "$pkg"; or continue
        for tag in (string split ',' -- "$parts[2]")
            if string match -q 'app-cluster=*' -- "$tag"
                string replace 'app-cluster=' '' -- "$tag"
                return
            end
        end
        return
    end
end

# has_abi_tagged_dependency PKG → 0 when any transitive dependency carries an
# abi tag. Such a package is a batch MEMBER (its rebuild is obligated by its
# anchor), never an anchor — which is why a leaf `--no-deps qt6-svg` or
# `--no-deps rust-git` is never gated, while llvm-git/qt*-base-git (untagged
# ancestors) are. The graph is acyclic (the loader's topo check proved it),
# so the recursion terminates.
function has_abi_tagged_dependency -a pkg
    for dep in (deps_of $pkg)
        if test (package_abi_severity $dep) != none
            return 0
        end
        if has_abi_tagged_dependency $dep
            return 0
        end
    end
    return 1
end

# abi_depends_on PKG TARGET → 0 when PKG transitively depends on TARGET.
function abi_depends_on -a pkg target
    for dep in (deps_of $pkg)
        test "$dep" = "$target"; and return 0
        if abi_depends_on $dep $target
            return 0
        end
    end
    return 1
end

# abi_batch_dependents ANCHOR → every abi-tagged package that transitively
# depends on ANCHOR (the reverse closure the edge file cannot express), one
# per line, in map order.
function abi_batch_dependents -a anchor
    for candidate in $_PACKAGE_IDS
        test (package_abi_severity $candidate) = none; and continue
        test "$candidate" = "$anchor"; and continue
        if abi_depends_on $candidate $anchor
            echo $candidate
        end
    end
end

function fmt_dur -a secs
    printf '%dm%02ds' (math "floor($secs / 60)") (math "$secs % 60")
end

function package_log_file -a pkg
    echo "$LOG_DIR/"(basename "$pkg")".log"
end

# What this run rewrote in the tree through version/checksum sync, as run-level
# witness: a run never commits (the disposition of these edits is the owner's),
# so the end-of-run summary must name every recipe whose PKGBUILD the sync or
# the sum refresh touched — otherwise the dirty tree has only a per-package
# log line nobody reads. Lane children append (best-effort); run_lanes clears
# the file at run start.
function print_synced_notes
    set -l f "$_STATE_DIR/synced.list"
    if not test -s "$f"
        return 0
    end
    echo "Version and checksum sync this run (uncommitted — review with 'git diff', then commit):"
    sed 's/^/  /' "$f"
end

# ─── Runtime-state ownership: settled at write time ─────────────────────────
# 2026-09-23 incident: root mode opened its logs through the SUPERVISOR's
# shell redirects and repaired ownership only at build_package exit, so a run
# killed mid-flight left the in-flight logs (and .state/ itself) root-owned.
# The next unprivileged run aborted at the lane-spawn redirect with a
# misleading "BUILD FAILED (rc=125, 0m00s)" — the build never started, and
# the crashed run's log content was left unopenable. The contract now:
#   * directories — ensure_state_dirs: root mode sweeps $_STATE_DIR to the
#     build user at startup; unprivileged mode refuses to run when LOG_DIR is
#     not writable and names the fix.
#   * files — ensure_log_writable before every create/truncate/append: root
#     mode creates as the build user (NEVER as root — root creation is what
#     poisons the next run) and repairs wrong owners; unprivileged mode
#     QUARANTINES an unopenable log by rename (forensics preserved under a
#     .stale name, announcement on stderr — never a silent truncate) or fails
#     with the exact chown/rm command.
# Forensics sites call this best-effort: a broken forensics channel must
# report, not break, the run that is recording in it.
function log_ownership_hint
    printf '    fix: sudo chown -R %s: %s\n' "$_BUILD_USER" "'$_STATE_DIR'" >&2
    printf '    (or remove the named file: sudo rm <file>)\n' >&2
end

function ensure_state_dirs
    if not mkdir -p "$_STATE_DIR" "$LOG_DIR" "$_STATE_DIR/toolchains"
        ui_error "cannot create builder state directories: $_STATE_DIR"
        log_ownership_hint
        return 1
    end
    if test "$_ROOT_MODE" = "1"
        # One sweep repairs directories AND files an earlier interrupted root
        # run left behind. Idempotent, and the tree is small (logs + lock +
        # shim + per-recipe toolchain identities); build_package already pays
        # an equal chown -R per package.
        if not chown -R "$_BUILD_USER": "$_STATE_DIR" 2>/dev/null
            ui_error "cannot restore ownership of runtime state: $_STATE_DIR"
            log_ownership_hint
            return 1
        end
    else if not test -w "$LOG_DIR"; or not test -w "$_STATE_DIR/toolchains"
        ui_error "cannot write builder state directories: $_STATE_DIR"
        log_ownership_hint
        return 1
    end
    return 0
end

function ensure_log_writable -a file
    if test -z "$file"
        ui_error "internal error: ensure_log_writable called without a path"
        return 1
    end
    if test "$_ROOT_MODE" = "1"
        if test -e "$file"
            set -l owner (stat -c %U -- "$file" 2>/dev/null)
            if test "$owner" = "$_BUILD_USER"
                return 0
            end
            if not chown "$_BUILD_USER": "$file" 2>/dev/null
                ui_error "cannot repair ownership of runtime file: $file (owner: $owner)"
                log_ownership_hint
                return 1
            end
            printf '⚠ repaired root-owned runtime file: %s -> %s\n' "$file" "$_BUILD_USER" >&2
            return 0
        end
        # Create AS THE BUILD USER. A root fallback touch here would re-create
        # the incident: root creation is precisely what poisons the next run.
        if not sudo -u "$_BUILD_USER" touch "$file" 2>/dev/null
            ui_error "cannot create runtime file as $_BUILD_USER: $file"
            log_ownership_hint
            return 1
        end
        return 0
    end
    # Unprivileged: the build user cannot chown, so an unopenable file (root-
    # owned 0644 from a crashed root run, chmod'ed away, ...) is preserved
    # under a unique .stale name — rename needs only directory write, which
    # ensure_state_dirs has already gated — and a fresh log starts. The old
    # content is the crashed run's forensics: never truncated in place.
    if test -e "$file"; and not test -w "$file"
        set -l stale "$file.stale."(date +%s)"."
        set stale "$stale$fish_pid"
        if not mv -- "$file" "$stale" 2>/dev/null
            ui_error "cannot write runtime file (not writable by "(id -un)"): $file"
            log_ownership_hint
            printf '    or: sudo rm %s\n' "$file" >&2
            return 1
        end
        printf '⚠ preserved unopenable log: %s -> %s (not writable by %s)\n' \
            "$file" "$stale" (id -un) >&2
    end
    return 0
end

function require_command -a command_name
    if not command -v "$command_name" >/dev/null 2>&1
        ui_error "required command '$command_name' is unavailable"
        return 1
    end
    return 0
end

# Resolve pacman's database ROOT the way makepkg itself does —
# `pacman-conf DBPath` — falling back to the stock /var/lib/pacman. Besides
# honouring a non-default DBPath, this gives fixtures a PATH-stubbable
# `pacman-conf` seam so they never probe (or touch) the host's real
# /var/lib/pacman/{db.lck,local}. No GSA_* test knob exists for this.
function pacman_db_path
    if command -q pacman-conf
        set -l db_path (pacman-conf DBPath 2>/dev/null | string trim)
        if test -n "$db_path"; and string match -q '/*' -- "$db_path"
            echo "$db_path"
            return 0
        end
    end
    echo /var/lib/pacman
end

function pacman_db_lock_path
    echo (pacman_db_path)"/db.lck"
end

# The local (installed-package) database: every entry here is a directory
# <pkgname>-<pkgver>-<pkgrel> holding at least `desc` and `files`.
function pacman_db_local_path
    echo (pacman_db_path)"/local"
end

# One "holder pid=N cmd=..." line per live lock holder on stdout. Empty
# output = proven idle; any line (including an "unknown" line when pgrep is
# missing) = treat as busy and NEVER remove the lock.
function pacman_lock_holder_lines
    if not command -q pgrep
        echo "  holder unknown: pgrep is unavailable — cannot prove the lock idle"
        return 0
    end
    set -l holder_pids
    for name in pacman packagekitd pamac
        set -a holder_pids (pgrep -x "$name" 2>/dev/null)
    end
    for pid in $holder_pids
        set -l cmd (ps -o args= -p "$pid" 2>/dev/null | string trim)
        test -n "$cmd"; or set cmd "(cmdline unavailable)"
        printf '  holder pid=%s cmd=%s\n' "$pid" "$cmd"
    end
end

function pacman_lock_busy_report -a lock_path
    ui_warning "pacman database lock exists: $lock_path"
    for line in $argv[2..-1]
        echo "$line"
    end
    echo "  Recovery: wait for a running transaction to finish; if its process has"
    echo "  crashed (stale lock), verify nothing holds it and remove it manually:"
    echo "    sudo rm -f $lock_path"
end

# check_pacman_lock <path> — report-only probe PLUS guarded stale removal.
# Reconciliation note (2026-09-23): the older never-remove todo predates the
# user's explicit re-approval of idle-removal that same day after the lock
# storm (plan.md decision `lock_strategy = both`). Merged rule: NEVER remove
# while any holder exists; remove ONLY when two probes ~1 s apart both find
# nothing — that closes the appear-between-probes race.
# rc 0 = absent or removed (clear to install), rc 1 = busy/unremovable.
function check_pacman_lock -a lock_path
    if test -z "$lock_path"; or not test -e "$lock_path"
        return 0
    end
    set -l holders (pacman_lock_holder_lines)
    if test (count $holders) -gt 0
        pacman_lock_busy_report "$lock_path" $holders
        return 1
    end
    sleep 1
    set holders (pacman_lock_holder_lines)
    if test (count $holders) -gt 0
        pacman_lock_busy_report "$lock_path" $holders
        return 1
    end
    # Provably idle twice — the case that hard-failed six installs on
    # 2026-09-23. LOUD on purpose: this mutates host state.
    if rm -f -- "$lock_path"
        ui_warning "STALE pacman lock removed (no holder on two probes 1 s apart): $lock_path"
        echo "  Why: the previous pacman/packagekitd/pamac died without unlocking its"
        echo "  database (2026-09-23 lock-storm incident). If installs fail next,"
        echo "  re-check the database before forcing anything else."
        return 0
    end
    ui_error "cannot remove the stale lock: $lock_path (permission denied?)"
    echo "  Remove it manually: sudo rm -f $lock_path"
    return 1
end

# Entry directories under <DBPath>/local whose `desc` and/or `files` member is
# absent. `find`, never a bare glob: an unmatched fish glob is fatal (house
# rule), and a fixture's local dir may legitimately be empty.
function pacman_db_broken_entries -a local_dir
    for entry in (find "$local_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
        if not test -f "$entry/desc"; or not test -f "$entry/files"
            echo "$entry"
        end
    end
end

# Usage: pacman_db_broken_report <local-dir> [holder-line ...] — print what is
# broken, who is alive, and how to recover.
function pacman_db_broken_report -a local_dir
    for entry in (pacman_db_broken_entries "$local_dir")
        echo "  broken: $entry (missing desc/files — interrupted pacman -U commit)"
    end
    for line in $argv[2..-1]
        echo "$line"
    end
    echo "  A live transaction may be committing these right now. If they stay"
    echo "  broken after it ends, the next builder run repairs them automatically"
    echo "  (idle removal), or fix by hand:"
    echo "    sudo rm -rf <entry>   then reinstall the package (-s -i / -ia)"
end

# check_pacman_db_health <local-dir> — report-only probe PLUS guarded removal
# of local database entries an interrupted `pacman -U` left behind mid-commit.
# Signature (2026-09-24 vscodium-insiders-git): the entry directory exists but
# `desc`/`files` never landed (only `mtree`, written 3 s before a window-close
# TERM killed pacman). From then on every transaction that loads the local db
# fails with pacman's MISLEADING `invalid or corrupted package` — blame lands
# on the ARCHIVE, which is perfectly fine — and makepkg's .BUILDINFO query
# prints the raw `desc` open error during the package() phase. The entry is
# unusable in every direction (-U, -R, -Ql all hard-fail), so removal plus
# reinstall is the only repair; pacman -R cannot even read it.
# Rules mirror check_pacman_lock: NEVER touch anything while a pacman/
# packagekitd/pamac holder exists (a live transaction may legitimately be
# mid-commit); remove ONLY when two probes 1 s apart find the box idle; LOUD,
# because this mutates host state. In non-root runs `rm -rf` fails like the
# lock probe does and prints the manual sudo line instead.
# rc 0 = nothing broken, or the broken entries were removed; rc 1 = broken
# entries remain (busy holder or permission denied).
function check_pacman_db_health -a local_dir
    if test -z "$local_dir"; or not test -d "$local_dir"
        return 0
    end
    set -l broken (pacman_db_broken_entries "$local_dir")
    if test (count $broken) -eq 0
        return 0
    end
    set -l holders (pacman_lock_holder_lines)
    if test (count $holders) -gt 0
        ui_warning "local package database has "(count $broken)" broken entry(ies) but a transaction holder is alive — leaving them untouched:"
        pacman_db_broken_report "$local_dir" $holders
        return 1
    end
    sleep 1
    set broken (pacman_db_broken_entries "$local_dir")
    if test (count $broken) -eq 0
        return 0
    end
    set holders (pacman_lock_holder_lines)
    if test (count $holders) -gt 0
        ui_warning "local package database has "(count $broken)" broken entry(ies) but a transaction holder is alive — leaving them untouched:"
        pacman_db_broken_report "$local_dir" $holders
        return 1
    end
    # Provably idle twice — the same gate as the lock removal above.
    if rm -rf -- $broken
        ui_warning "BROKEN local package database entries removed (idle on two probes 1 s apart):"
        for entry in $broken
            echo "  removed: $entry"
        end
        echo "  Why: an interrupted pacman -U commit leaves the entry directory without"
        echo "  its desc/files members (2026-09-24 vscodium-insiders-git incident),"
        echo "  after which pacman rejects every later transaction with a misleading"
        echo "  'invalid or corrupted package'. The affected package(s) now count as"
        echo "  NOT installed — reinstall them next: 'build-all.fish -s -i' or '-ia'"
        echo "  reinstalls from the already-built archives."
        return 0
    end
    ui_error "cannot remove broken local package database entries (permission denied?):"
    for entry in $broken
        echo "  $entry"
    end
    echo "  Remove them manually, then reinstall the package(s):"
    echo "    sudo rm -rf <entry> && sudo pacman -U <archive>"
    return 1
end

# install_preflight MODE LABEL — the ONE shared install preflight: the db.lck
# probe and the local-db integrity probe as a single call, so every site that
# must know "can a pacman transaction right now" asks the same question.
#   refuse — fatal for an installing run: ui_error "refusing to LABEL while ..."
#            plus the one-line reason, rc 1. LABEL reads into the message
#            ("start an -i run", "start -ia").
#   warn   — build-only runs: non-fatal ui_warning "... building anyway;
#            -i/-ia would be refused until ..."
# Both probes self-heal (guarded stale removal) and print their own diagnostics
# — this layer only decides. Callers: check_runtime_prereqs (-i/-ia preflight),
# install_all (-ia entry). The post-mortem sites (run_pacman_locked's failure
# path, the interrupt teardown) call the probes directly: they always run both,
# report-only, and have no decision to make.
function install_preflight -a mode label
    set -l ok 1
    # db.lck preflight (2026-09-23 lock storm): a stale or held lock only
    # matters when this run will install — busy → refuse up front with the
    # recovery text; build-only runs just warn and keep building.
    if not check_pacman_lock (pacman_db_lock_path)
        switch $mode
            case refuse
                ui_error "refusing to $label while the pacman database lock is busy"
                echo "  Builds would succeed but every install would hard-fail on the held lock."
                set ok 0
            case warn
                ui_warning "pacman database lock is busy — building anyway; -i/-ia would be refused until it clears"
        end
    end
    # Local-db integrity preflight (2026-09-24 vscodium): a desc/files-less
    # entry makes every install fail with the misleading "invalid or
    # corrupted package" — busy holder → report and refuse up front;
    # provably idle → the probe removes it loudly so -s -i self-heals.
    if not check_pacman_db_health (pacman_db_local_path)
        switch $mode
            case refuse
                ui_error "refusing to $label while broken local package database entries exist (recovery hint above)"
                echo "  Builds would succeed but every install would hard-fail on the broken entry."
                set ok 0
            case warn
                ui_warning "broken local package database entries present — building anyway; -i/-ia would be refused until they are repaired"
        end
    end
    if test $ok -eq 0
        return 1
    end
    return 0
end

function check_runtime_prereqs -a install_flag needs_stable_sync
    set -l required fish makepkg nproc ps awk tail sed getent
    if test "$install_flag" = "1"; or test "$needs_stable_sync" = "1"
        set -a required pacman
    end
    if test "$install_flag" = "1"
        set -a required flock pacman
        # pgo_payload_refusals unrolls the archive to inspect its payload.
        set -a required tar strings
        if test "$_ROOT_MODE" != "1"
            set -a required sudo
        end
    end
    for command_name in $required
        if not require_command "$command_name"
            return 1
        end
    end
    if test "$install_flag" = "1"
        install_preflight refuse "start an -i run"; or return 1
    else
        install_preflight warn ""
    end
    return 0
end

# What can sudo do RIGHT NOW? Never prompts: lane children have no tty, and the
# dispatcher must not block on a password nobody may type.
#   fresh    — `sudo -n -v` refreshed the cached credential
#   nopasswd — the credential cannot be refreshed, but installs are
#              password-free anyway. Stopping the run here is WRONG: a dual
#              sudoers set ("(ALL) ALL" + "(ALL : ALL) NOPASSWD: ALL") makes
#              `sudo -v` fail forever while every `sudo -n` install succeeds —
#              the 2026-09-17 incident that stopped long runs for nothing.
#   cold     — sudo cannot run anything without a password right now
# The last probe runs the mechanism the lanes themselves use (`sudo -n pacman`),
# so its verdict cannot be rosier than an install would be. If a host has a
# password-free rule for that probe but a password-gated pacman, the run keeps
# dispatching and the lane's install still fails loudly and stops dispatch.
function sudo_probe
    if sudo -n -v >/dev/null 2>&1
        echo fresh
        return 0
    end
    if sudo -n pacman --version >/dev/null 2>&1
        echo nopasswd
        return 0
    end
    echo cold
    return 1
end

# Last resort when a credential dies mid-run: there is none. Every privilege
# escalation is `sudo -n` (2026-09-26 decision) — the builder never prompts,
# so a dead credential fails fast instead of hanging an unattended run.

# ─── Lane result codec: the process boundary's one format ────────────────────
# One wire line: `pkg rc dur [reason]`, space-separated — the reason rides
# only on deferrals that carry one. encode/decode are THE pair that defines
# it — the producer (write_lane_result) and the consumer (run_lanes' reap)
# both go through them, so the format has one home and one test surface.
# decode enforces shape AND identity (field 1 must equal the expected
# package), so a stale result file from another child can never be misread as
# this one's outcome. The rc field carries the lane_outcome_* vocabulary (see
# its block at the top of this file). A legacy 3-field line decodes to three
# lines; consumers fall back to the row grammar's default reason
# (anchoring-refused) when there is no fourth.

# lane_result_encode PKG RC DUR [REASON] → the wire line on stdout; fails on
# an empty pkg (identity is mandatory), a non-numeric rc/dur (the outcome
# vocabulary is numeric by construction), or a malformed reason token.
function lane_result_encode -a pkg rc dur reason
    if test -z "$pkg"
        return 1
    end
    if not string match -qr '^[0-9]+$' -- "$rc"
        return 1
    end
    if not string match -qr '^[0-9]+$' -- "$dur"
        return 1
    end
    if test -n "$reason"
        if not string match -qr '^[a-z0-9][a-z0-9-]*$' -- "$reason"
            return 1
        end
        printf '%s %s %s %s\n' "$pkg" "$rc" "$dur" "$reason"
        return 0
    end
    printf '%s %s %s\n' "$pkg" "$rc" "$dur"
end

# lane_result_decode EXPECTED_PKG LINE → three lines (pkg, rc, dur), plus a
# fourth (reason) when the wire carried one, for fish command substitution,
# which splits on newlines only; fails on any shape, identity or numeric
# mismatch. Callers treat failure as "no valid result".
function lane_result_decode -a expected_pkg result_line
    set -l fields
    for field in (string split ' ' -- "$result_line")
        if test -n "$field"
            set -a fields "$field"
        end
    end
    if test (count $fields) -ne 3; and test (count $fields) -ne 4
        return 1
    end
    if test "$fields[1]" != "$expected_pkg"
        return 1
    end
    if not string match -qr '^[0-9]+$' -- "$fields[2]"
        return 1
    end
    if not string match -qr '^[0-9]+$' -- "$fields[3]"
        return 1
    end
    if test (count $fields) -eq 4
        if not string match -qr '^[a-z0-9][a-z0-9-]*$' -- "$fields[4]"
            return 1
        end
        printf '%s\n%s\n%s\n%s\n' "$fields[1]" "$fields[2]" "$fields[3]" "$fields[4]"
        return 0
    end
    printf '%s\n' "$fields[1]" "$fields[2]" "$fields[3]"
end

# write_lane_result RESULT_FILE PKG RC DUR [REASON] — the producer side of
# the codec: encode, then publish atomically. The wire line and the atomic mv
# contract are unchanged.
function write_lane_result -a result_file pkg rc dur reason
    set -l line (lane_result_encode "$pkg" "$rc" "$dur" "$reason")
    if test (count $line) -ne 1
        return 1
    end
    set -l tmp_result "$result_file.tmp.$fish_pid"
    if not printf '%s\n' "$line" >"$tmp_result"
        rm -f -- "$tmp_result"
        return 1
    end
    # Write-time ownership: in root mode the lane child creates this tmp as
    # root, so hand it to the build user BEFORE the atomic publish — the
    # published result must never be root-owned. A SIGKILL between printf and
    # chown strands only the tmp (next run rm -f's by directory permission).
    if test "$_ROOT_MODE" = "1"; and not chown "$_BUILD_USER": "$tmp_result" 2>/dev/null
        rm -f -- "$tmp_result"
        return 1
    end
    if not mv -f -- "$tmp_result" "$result_file"
        rm -f -- "$tmp_result"
        return 1
    end
    return 0
end

function dashboard_width
    if test "$_OUTPUT_INTERACTIVE" != "1"
        echo 0
        return 0
    end

    set -l width ""
    set width (tput cols 2>/dev/null)
    if test (count $width) -eq 0; or not string match -qr '^[0-9]+$' -- "$width[1]"
        if test -n "$COLUMNS"; and string match -qr '^[0-9]+$' -- "$COLUMNS"
            set width "$COLUMNS"
        end
    end
    if test (count $width) -eq 0; or not string match -qr '^[0-9]+$' -- "$width[1]"
        set width 80
    else
        set width "$width[1]"
    end
    if test "$width" -lt 20
        set width 20
    end
    echo "$width"
end

function fit_dashboard_line -a text width
    # Keep one cell unused so a terminal never enters its pending-wrap state.
    set -l max_width (math "$width - 1")
    if test "$max_width" -lt 1
        set max_width 1
    end
    set -l text_length (string length --visible -- "$text")
    if test "$text_length" -le "$max_width"
        printf '%s' "$text"
    else
        set -l suffix ""
        set -l target_width "$max_width"
        if test "$max_width" -gt 3
            set suffix "..."
            set target_width (math "$max_width - 3")
        end
        set -l prefix ""
        for char in (string split '' -- "$text")
            set -l candidate "$prefix$char"
            if test (string length --visible -- "$candidate") -gt "$target_width"
                break
            end
            set prefix "$candidate"
        end
        printf '%s%s' "$prefix" "$suffix"
    end
end

function render_dashboard -a total dispatched succeeded failed stop_starting
    if test "$_OUTPUT_INTERACTIVE" != "1"
        return 0
    end

    set -l state RUNNING
    set -l state_icon "$_UI_ICON_ACTIVE"
    if test "$failed" -gt 0
        set state FAILED
        set state_icon "$_UI_ICON_ERROR"
    else if test "$stop_starting" -eq 1
        set state STOPPING
        set state_icon "$_UI_ICON_WARN"
    else if test "$succeeded" -eq "$total"; and test "$total" -gt 0
        set state DONE
        set state_icon "$_UI_ICON_OK"
    end

    set -l rows
    set -a rows "Progress: $dispatched/$total started | $succeeded done | $failed failed | $state_icon $state"
    for i in (seq (count $_DASHBOARD_LANE_BUSY))
        if test "$_DASHBOARD_LANE_BUSY[$i]" -eq 1
            set -l elapsed (math (date +%s) - $_DASHBOARD_LANE_START[$i])
            set -l lane_name (basename "$_DASHBOARD_LANE_PKG[$i]")
            set -l elapsed_fmt (fmt_dur $elapsed)
            set -a rows "Lane $i: $_UI_ICON_ACTIVE RUNNING $lane_name $elapsed_fmt"
            set -a rows (dashboard_tail_rows "$_DASHBOARD_LANE_PKG[$i]")
        else
            set -a rows "Lane $i: $_UI_ICON_INFO idle"
            set -a rows (dashboard_tail_rows "")
        end
    end
    if test -n "$_DASHBOARD_LAST_EVENT"
        set -a rows "$_DASHBOARD_SPINNER_FRAMES[$_DASHBOARD_SPINNER_INDEX] Event: $_DASHBOARD_LAST_EVENT"
    end

    set -l old_rows $_DASHBOARD_ROWS
    if test "$_DASHBOARD_ACTIVE" != "1"
        printf '\033[?25l'
    end
    if test "$old_rows" -gt 0
        printf '\033[%dA' "$old_rows"
    end
    set -l width (dashboard_width)
    for row in $rows
        printf '\r\033[2K%s\n' (fit_dashboard_line "$row" "$width")
    end
    # The row count is intentionally stable during a run, but clear any
    # remainder if a future state adds fewer rows.
    set -l new_rows (count $rows)
    if test "$old_rows" -gt "$new_rows"
        for i in (seq (math "$new_rows + 1") "$old_rows")
            printf '\r\033[2K\n'
        end
    end
    set -g _DASHBOARD_ROWS $new_rows
    set -g _DASHBOARD_ACTIVE 1
end

function finish_dashboard
    if test "$_DASHBOARD_ACTIVE" = "1"
        printf '\033[?25h'
        set -g _DASHBOARD_ACTIVE 0
        set -g _DASHBOARD_ROWS 0
    end
end

function abort_dashboard
    if test "$_DASHBOARD_ACTIVE" = "1"
        set -l rows $_DASHBOARD_ROWS
        if test "$rows" -gt 0
            printf '\033[%dA' "$rows"
            for i in (seq $rows)
                printf '\r\033[2K'
                if test "$i" -lt "$rows"
                    printf '\033[1B'
                end
            end
            if test "$rows" -gt 1
                printf '\033[%dA' (math "$rows - 1")
            end
        end
        printf '\033[?25h'
    end
    set -g _DASHBOARD_ACTIVE 0
    set -g _DASHBOARD_ROWS 0
end

function forget_lane_pid -a pid
    if test -z "$pid"; or test (count $_ACTIVE_LANE_PIDS) -eq 0
        return 0
    end
    for i in (seq (count $_ACTIVE_LANE_PIDS))
        if test "$_ACTIVE_LANE_PIDS[$i]" = "$pid"
            set -e _ACTIVE_LANE_PIDS[$i]
            # Erase the SAME index of the parallel package list so the two
            # arrays stay paired (cleanup_active_lanes reads them by index).
            if test $i -le (count $_ACTIVE_LANE_PKGS)
                set -e _ACTIVE_LANE_PKGS[$i]
            end
            return 0
        end
    end
end

function lane_processes -a lane_pid
    # Zombies excluded: a finished-but-unreaped lane head must not consume
    # the whole stop grace — SIGKILL on a zombie is a no-op anyway.
    ps -eo pid=,pgid=,stat= 2>/dev/null \
        | awk -v target="$lane_pid" '$2 == target && $3 !~ /^Z/ {print $1}'
end

function lane_pid_alive -a lane_pid
    test -n "$lane_pid"; or return 1
    set -l process_state (ps -o stat= -p "$lane_pid" 2>/dev/null | string trim)
    test -n "$process_state"; or return 1
    string match -q '*Z*' -- "$process_state"; and return 1
    kill -0 "$lane_pid" 2>/dev/null
end

function stop_lane_process -a lane_pid reason pkg
    if test -z "$lane_pid"
        return 0
    end
    set -l why "$reason"
    test -n "$why"; or set why unspecified
    set -l pkg_label '-'
    test -n "$pkg"; and set pkg_label "$pkg"
    set -l lane_process_ids (lane_processes "$lane_pid")
    # Precompute the join: a failed substitution (string join with an EMPTY
    # list) makes fish skip the whole statement — forensics must survive an
    # already-empty pgrp.
    set -l pid_list '-'
    if test (count $lane_process_ids) -gt 0
        set pid_list (string join ',' -- $lane_process_ids)
    end
    dispatcher_log "stop begin reason=$why pgid=$lane_pid pkg=$pkg_label pids=$pid_list"
    # ONE TERM per PID, then a real grace window before a single SIGKILL
    # sweep. The 2026-09-23 incident: the previous loop re-TERMed the whole
    # pgrp every 50 ms and SIGKILLed at ~0.5 s, so a running `pacman -U` was
    # interrupted DURING its db.lck unlock — six installs on the next run
    # died on "could not lock database: File exists". A transaction that
    # survived the TERM needs time to finish unlocking; a child that IGNORES
    # TERM must still not survive, hence the bounded grace below.
    for process_id in $lane_process_ids
        kill -TERM "$process_id" 2>/dev/null
    end
    # Wall-clock deadline (not a poll count): each poll also pays a ps+awk,
    # so counting iterations would stretch "30 s" to 35+ s under load.
    set -l grace_deadline (math (date +%s) + $_LANE_STOP_GRACE_S)
    while true
        set lane_process_ids (lane_processes "$lane_pid")
        if test (count $lane_process_ids) -eq 0
            break
        end
        if test (date +%s) -ge $grace_deadline
            break
        end
        sleep 0.1
    end
    set lane_process_ids (lane_processes "$lane_pid")
    for process_id in $lane_process_ids
        # Escalation is exceptional and must be auditable in BOTH logs.
        dispatcher_log "escalate: pid=$process_id pgid=$lane_pid pkg=$pkg_label SIGKILL after grace reason=$why"
        if test -n "$pkg"
            set -l pkg_log (package_log_file "$pkg")
            # Best-effort forensics: quarantine/repair first, skip the line
            # only if even that cannot make the log writable (the same event
            # is already mirrored to dispatcher.log above).
            if ensure_log_writable "$pkg_log"
                printf '%s [DEBUG-gsa-term] escalate: pid=%s SIGKILL after %ss grace (reason=%s)\n' \
                    "$_UI_ICON_WARN" "$process_id" "$_LANE_STOP_GRACE_S" "$why" >>"$pkg_log"
            end
        end
        kill -KILL "$process_id" 2>/dev/null
    end
    if test (count $lane_process_ids) -gt 0
        # Brief post-KILL settle: lane_processes ignores zombies, so this only
        # waits for stragglers actually still running after SIGKILL.
        for poll in (seq 20)
            set lane_process_ids (lane_processes "$lane_pid")
            test (count $lane_process_ids) -eq 0; and break
            sleep 0.1
        end
    end
    wait "$lane_pid" 2>/dev/null
end

function cleanup_active_lanes
    dispatcher_log "cleanup begin count="(count $_ACTIVE_LANE_PIDS)
    set -l active_pids $_ACTIVE_LANE_PIDS
    for i in (seq (count $active_pids))
        set -l pkg ''
        if test $i -le (count $_ACTIVE_LANE_PKGS)
            set pkg $_ACTIVE_LANE_PKGS[$i]
        end
        stop_lane_process "$active_pids[$i]" interrupt "$pkg"
    end
    set -g _ACTIVE_LANE_PIDS
    set -g _ACTIVE_LANE_PKGS
    find "$LOG_DIR" -maxdepth 1 -name '.lane*.result' -delete 2>/dev/null
    dispatcher_log "cleanup done"
end

function check_rustc_sanity
    # Preflight ABI-skew probe (2026-09-07 incident): a trivial rustc compile
    # catches llvm-libs-git-vs-rust-git snapshot skew in ~2 s — BEFORE a run
    # wastes an hour building against a compiler that segfaults on any input.
    pacman -Q rust-git >/dev/null 2>&1; or return 0
    command -v rustc >/dev/null 2>&1; or return 0
    # Per-user probe files: /tmp has the sticky bit + fs.protected_regular=2,
    # so even ROOT cannot redirect over a file owned by another user — name
    # collisions between user-mode and root-mode runs must be impossible.
    # Sanitized: rustc derives the crate name from the output file, so only
    # [A-Za-z0-9_] may appear (dots/dashes in usernames break it).
    set -l user_tag (string replace -r '[^a-zA-Z0-9_]' '_' -- "$_BUILD_USER")
    set -l probe /tmp/build_all_rustc_probe_$user_tag
    if not echo 'fn main() {}' >"$probe.rs"
        ui_error "cannot create rustc sanity probe: $probe.rs"
        return 1
    end
    set -l ok 0
    if test "$_ROOT_MODE" = "1"
        if sudo -u "$_BUILD_USER" env HOME=$_BUILD_HOME rustc -o "$probe.bin" "$probe.rs" 2>/dev/null
            set ok 1
        end
    else
        if rustc -o "$probe.bin" "$probe.rs" 2>/dev/null
            set ok 1
        end
    end
    if not rm -f -- "$probe.rs" "$probe.bin"
        ui_warning "could not remove rustc sanity probe files under /tmp"
    end
    if test $ok -eq 0
        ui_error "rustc is BROKEN — segfaults/heap-corrupts on a trivial compile."
        echo "  Almost certainly llvm-libs-git is NEWER than rust-git (LLVM snapshots"
        echo "  have no stable C++ ABI — see NOTE.md 2026-09-07 evening). Every build"
        echo "  using rustc in this run would fail or miscompile."
        echo "  Recovery: downgrade-rebuild llvm-libs at the snapshot rust-git was built"
        echo "  against (old version in /var/log/pacman.log; procedure in NOTE.md), or"
        echo "  -g core once a working bootstrap exists."
        echo "  Bypass anyway: --allow-broken-rustc"
        return 1
    end
    return 0
end

# probe_refusal_text — the recovery prose for the ONLY remaining probe refusal
# path (2026-10-02 owner rule): a toolchain sanity-probe failure whose
# remediation cannot be built (no chain identifiable) or whose remediation
# build itself failed. Pure printing — the caller sets the abort state. A
# failing probe alone no longer refuses; refusal is remediation failure.
function probe_refusal_text
    echo "  The selection must rebuild rust-git in the same pass before anything"
    echo "  else compiles with rustc — stopping dispatch, draining in-flight lanes."
    echo "  Recovery: rebuild rust-git in the same run (add rust-git to the selection"
    echo "  and resume with -s -i), or follow the check_rustc_sanity recovery text"
    echo "  above (downgrade-rebuild llvm-libs at the snapshot rust-git was built"
    echo "  against)."
end

# toolchain_remediation_plan TOOLCHAIN_PKG BROKEN_CONSUMER — the force-build
# chain that reconciles the at-risk chain after a sanity-probe failure (owner
# rule 2026-10-02: remediation-by-rebuild, never abort-while-remediable).
# Prints ONE kind line ('narrow' or 'core') followed by the chain, one package
# id per line. Narrow identification: BROKEN_CONSUMER (the consumer the probe
# implicates — rust-git for the rustc probe; any tool-clang/llvm consumer for a
# future clang-side probe) is a known package AND a consumer of TOOLCHAIN_PKG
# in the topology's ABI direction (expand_consumers/_CONSUMER_INDEX). When the
# broken consumer cannot be identified narrowly — unknown package, not a
# consumer of the toolchain package, or the consumer walk itself fails — the
# plan degrades to the WHOLE core group: the general tool-clang/llvm consumer
# chain, not just rustc. A bare kind line with no chain means remediation is
# impossible and the caller keeps the refusal contract.
function toolchain_remediation_plan -a toolchain_pkg broken_consumer
    if test (count $_CONSUMER_INDEX) -eq 0
        read_topology_config
    end
    set -l closure (expand_consumers "$toolchain_pkg")
    set -l closure_rc $status
    if test $closure_rc -eq 0; and test -n "$broken_consumer"
        if package_path "$broken_consumer" >/dev/null
            if contains "$broken_consumer" $closure
                printf '%s\n' narrow "$broken_consumer"
                return 0
            end
        end
    end
    printf '%s\n' core
    for pkg in $_GROUP_core
        printf '%s\n' "$pkg"
    end
    return 0
end

# force_queue_packages PKG... → prints how many ids it added. Makes
# remediation targets dispatchable mid-run through the EXISTING dispatch
# machinery: membership in $_lane_sorted is what pick_next_ready walks and
# $_RR_ORDER is what run_record_finalize keeps rows for. Ids already queued
# keep their position (topological order before anything appended).
function force_queue_packages
    set -l added 0
    for pkg in $argv
        if not contains "$pkg" $_lane_sorted
            set -a _lane_sorted "$pkg"
            set -a _RR_ORDER "$pkg"
            set added (math $added + 1)
        end
    end
    echo $added
end

# True when $pkg transitively depends (within the build list) on a recipe this
# run deferred — used to label unstarted packages honestly: waiting on a
# parked recipe is not the dependency cycle the old message claimed. The graph
# is acyclic (topo_sort validated it), so the recursion terminates.
function waits_on_deferred -a pkg
    if test (count $_lane_deferred) -eq 0
        return 1
    end
    for dep in (deps_of $pkg)
        if not contains "$dep" $_lane_sorted
            continue
        end
        if contains "$dep" $_lane_deferred
            return 0
        end
        if waits_on_deferred $dep
            return 0
        end
    end
    return 1
end

function pick_next_ready -a solo_ok
    # Print the first unstarted package whose workspace deps are all done.
    # solo_ok=0 skips core-group packages (they are only dispatched solo).
    # argv[2..] = optional RESTRICT set: the toolchain-remediation force queue
    # (2026-10-02). With a restrict set the pick is FORCE semantics — a queued
    # package may dispatch again even though an earlier attempt already landed
    # in _lane_started/_lane_done (the rebuild is the point) — but never while
    # an earlier lane for it is still in flight (no double dispatch), and a
    # dependency that is itself queued for rebuild must be rebuilt first.
    set -l restrict $argv[2..-1]
    set -l force_mode 0
    if test (count $restrict) -gt 0
        set force_mode 1
    end
    for pkg in $_lane_sorted
        if test $force_mode -eq 1
            if not contains "$pkg" $restrict
                continue
            end
            if test (count $_lane_started) -gt 0; and contains "$pkg" $_lane_started; and not contains "$pkg" $_lane_done
                continue
            end
        else
            if test (count $_lane_started) -gt 0; and contains "$pkg" $_lane_started
                continue
            end
            # Defensive: _lane_started is a superset of _lane_done in run_lanes,
            # but never re-dispatch a completed package even if that breaks.
            if test (count $_lane_done) -gt 0; and contains "$pkg" $_lane_done
                continue
            end
        end
        set -l ok 1
        for dep in (deps_of $pkg)
            # Deps outside the build list are external — topo_sort ignores
            # them, the readiness check must too (they will never be "done").
            if not contains "$dep" $_lane_sorted
                continue
            end
            # A remediation rebuild of the dep comes first: the dep being in
            # _lane_done from an earlier attempt says nothing about the state
            # the forced rebuild is reconciling to.
            if test $force_mode -eq 1
                if contains "$dep" $_REMED_PENDING; or contains "$dep" $_REMED_ACTIVE
                    set ok 0
                    break
                end
            end
            # A deferred dep IS in _lane_done (the lane finished, parked), but
            # its package was never built or installed — dispatching the
            # dependent would compile it against the wrong system state.
            if test (count $_lane_deferred) -gt 0; and contains "$dep" $_lane_deferred
                set ok 0
                break
            end
            if test (count $_lane_done) -eq 0; or not contains "$dep" $_lane_done
                set ok 0
                break
            end
        end
        if test $ok -eq 0
            continue
        end
        if test $solo_ok -eq 0; and contains "$pkg" $_GROUP_core
            continue
        end
        echo $pkg
        return 0
    end
    return 1
end

# ─── Lane invocation: one description of the process-boundary argv ───────────
# The seam stays the PROCESS BOUNDARY: `--lane-job` + 8 positional payload
# args (pkg, result file, jobs, five 0|1 flags), unchanged. But the shape now
# has one home: lane_argv builds the payload (the spawn) and lane_argv_check
# validates exactly that shape (the handler). Adding a lane flag is a two-line
# edit here plus the lane_job signature — never argv archaeology through a
# count check at the call site.

# lane_argv PKG RESULT_FILE JOBS INSTALL CLEAN SKIP NO_SYNC FORCE → the eight
# payload args, one per line (fish command substitution splits on newlines).
function lane_argv -a pkg result_file jobs install_flag clean_flag skip_flag no_sync_flag force_install_flag
    printf '%s\n' "$pkg" "$result_file" "$jobs" "$install_flag" "$clean_flag" "$skip_flag" "$no_sync_flag" "$force_install_flag"
end

# lane_argv_check ARGS... — validate the payload shape lane_argv builds.
# Silent and rc 0 when valid; prints the error and returns 2 on an invalid
# invocation. 2 is invocation error: outside the lane_outcome_* vocabulary,
# never written to a result file.
function lane_argv_check
    if test (count $argv) -ne 8
        echo "Error: --lane-job expects package, result file, job count, and five flags" >&2
        return 2
    end
    if not string match -qr '^[1-9][0-9]*$' -- "$argv[3]"
        echo "Error: --lane-job received an invalid job count: $argv[3]" >&2
        return 2
    end
    for flag in $argv[4..8]
        if not string match -qr '^[01]$' -- "$flag"
            echo "Error: --lane-job received an invalid flag: $flag" >&2
            return 2
        end
    end
    return 0
end

# lane_job PKG_ID RESULT_FILE TOTAL_JOBS INSTALL CLEAN SKIP NO_SYNC FORCE —
# the lane child's body. PKG_ID is the package ID (the misnomer `pkg_dir` was
# renamed: this has always received the ID, which is also the result line's
# identity field). Result protocol: build, then ONE honest `pkg rc dur` line
# through the codec.
function lane_job -a pkg_id result_file total_jobs install_flag clean_flag skip_flag no_sync_flag force_install_flag
    # Runs in a separate fish process with its stdout/stderr redirected by the
    # parent: no tty for sudo, no shared mutable state — communicates by result file.
    # Route this lane's makepkg -s dep installs through the builder mutex
    # (see ensure_pacman_shim); fall back to plain pacman, never to a
    # nonexistent path — makepkg resolves $PACMAN with `type -P` and an
    # empty PACMAN_PATH would break every dep check.
    if ensure_pacman_shim
        set -gx PACMAN "$LOG_DIR/.pacman-shim"
    else
        echo "warning: could not generate $LOG_DIR/.pacman-shim — dep installs run unlocked" >&2
    end
    set -gx GSA_BUILD_JOBS "$total_jobs"
    set -l make_flags
    if set -q MAKEFLAGS
        for flag in (string split ' ' -- "$MAKEFLAGS")
            if test -n "$flag"; and not string match -qr '^-j[0-9]*$' -- "$flag"
                set -a make_flags "$flag"
            end
        end
    end
    set -a make_flags "-j$total_jobs"
    # Quoted list expansion, not `string join`: fish hands every argument after
    # the FIRST `string join` argument to its own option parser, so "-j4" made
    # the builtin fail ("unknown option") and left MAKEFLAGS unset — the lane
    # job budget silently never reached the build. A quoted variable joins the
    # list with spaces and cannot be mistaken for an option.
    set -gx MAKEFLAGS "$make_flags"
    set -l ninja_flags
    if set -q NINJAFLAGS
        for flag in (string split ' ' -- "$NINJAFLAGS")
            if test -n "$flag"; and not string match -qr '^-j[0-9]*$' -- "$flag"
                set -a ninja_flags "$flag"
            end
        end
    end
    set -a ninja_flags "-j$total_jobs"
    # See MAKEFLAGS above: `string join` cannot take a "-jN" argument.
    set -gx NINJAFLAGS "$ninja_flags"
    set -l start_s (date +%s)
    build_package $pkg_id $install_flag $clean_flag $skip_flag $no_sync_flag 1 $force_install_flag
    set -l rc $status
    set -l dur (math (date +%s) - $start_s)
    # A deferral carries WHY it parked when build_package named one (the
    # anchor branch stays silent and keeps the legacy default); every other
    # outcome has no reason field.
    set -l defer_reason ""
    if test "$rc" = "$lane_outcome_defer"; and set -q _DEFER_REASON
        set defer_reason "$_DEFER_REASON"
    end
    if not write_lane_result "$result_file" "$pkg_id" "$rc" "$dur" "$defer_reason"
        echo "✗ lane result write failed: $result_file" >&2
        # No valid result ⇒ the dispatcher classifies this lane as lost.
        exit $lane_outcome_lost
    end
    return $rc
end

function available_memory_gib
    if set -q GSA_MEMORY_GIB
        if not string match -qr '^[1-9][0-9]*$' -- "$GSA_MEMORY_GIB"
            ui_error "GSA_MEMORY_GIB must be a positive integer"
            return 1
        end
        echo "$GSA_MEMORY_GIB"
        return 0
    end
    if not test -r /proc/meminfo
        echo 0
        return 0
    end
    set -l memory_kib (awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo)
    if test -z "$memory_kib"; or not string match -qr '^[0-9]+$' -- "$memory_kib"
        echo 0
        return 0
    end
    math "floor($memory_kib / 1048576)"
end

function available_cpu_threads
    if set -q GSA_CPU_THREADS
        if not string match -qr '^[1-9][0-9]*$' -- "$GSA_CPU_THREADS"
            ui_error "GSA_CPU_THREADS must be a positive integer"
            return 1
        end
        echo "$GSA_CPU_THREADS"
        return 0
    end
    nproc
end

function run_lanes -a lanes jobs_override intensity_level install_flag clean_flag skip_flag no_sync_flag force_install_flag
    # Remaining argv = the topo-sorted package list
    set -l sorted $argv[9..-1]
    if not command -v setsid >/dev/null 2>&1
        ui_error "setsid is required for isolated lane processes"
        return 1
    end
    set -g _RL_INTERRUPTED 0
    set -g _RL_BLOCKED 0
    set -g _RL_DEFERRED
    set -g _RL_SUDO_NOTE ""
    set -g _lane_sorted $sorted
    set -g _lane_done
    set -g _lane_started
    set -g _lane_deferred

    set -l total (count $sorted)
    if test "$total" -eq 0
        ui_error "selection resolved to no packages"
        return 1
    end
    if not configure_intensity "$intensity_level"
        return 1
    end
    set -l needs_stable_sync 0
    if test "$no_sync_flag" != "1"
        for pkg in $sorted
            set -l pkg_path (package_path "$pkg")
            if string match -q "$SCRIPT_DIR/packages/stable/*" -- "$pkg_path"
                set needs_stable_sync 1
                break
            end
        end
    end
    if not check_runtime_prereqs "$install_flag" "$needs_stable_sync"
        return 1
    end
    set -l nproc_count (available_cpu_threads)
    if test $status -ne 0
        return 1
    end
    if test -z "$nproc_count"; or not string match -qr '^[0-9]+$' -- "$nproc_count"
        ui_error "nproc returned an invalid CPU count"
        return 1
    end
    set -l memory_gib (available_memory_gib)
    if test $status -ne 0
        return 1
    end
    if test "$memory_gib" -le 0
        set memory_gib 1
    end
    set -l normal_memory (math "max(1, $memory_gib - $_RESERVED_MEMORY_GIB)")
    set -l normal_memory_per_job (math "$_MEMORY_PER_JOB_GIB * $_INTENSITY_NORMAL_MEMORY_FACTOR")
    set -l normal_job_budget (math "max(1, floor($normal_memory / $normal_memory_per_job))")
    if test "$lanes" = auto
        set lanes (math "max(1, min($_INTENSITY_LANE_CAP, floor($nproc_count / $_INTENSITY_CPU_PER_LANE), floor($memory_gib / $_INTENSITY_MEMORY_PER_LANE), $normal_job_budget, $total))")
    else if not string match -qr '^[1-9][0-9]*$' -- "$lanes"
        ui_error "lane count must be a positive integer or auto"
        return 1
    end
    if test $lanes -gt $total
        set lanes $total
    end
    if test "$jobs_override" = auto
        set -l cpu_jobs (math "max(1, floor($nproc_count / $lanes))")
        set -l memory_jobs (math "max(1, floor($normal_job_budget / $lanes))")
        set lane_jobs (math "max(1, min($cpu_jobs, $memory_jobs))")
    else if string match -qr '^[1-9][0-9]*$' -- "$jobs_override"
        set lane_jobs "$jobs_override"
    else
        ui_error "jobs must be a positive integer or auto"
        return 1
    end
    set -l core_memory_per_job (math "$_CORE_MEMORY_PER_JOB_GIB * $_INTENSITY_CORE_MEMORY_FACTOR")
    set -l core_jobs (math "max(1, min($nproc_count, floor($normal_memory / $core_memory_per_job)))")
    ui_info "parallelism: $nproc_count CPU threads, $memory_gib GiB available, intensity $intensity_level, $lanes lane(s), normal -j$lane_jobs, core -j$core_jobs"
    # Plan scalars for the run record / machine block (this is the one place
    # the full plan is resolved and printed).
    set -g _RL_PLAN_LANES $lanes
    set -g _RL_PLAN_NORMAL_JOBS $lane_jobs
    set -g _RL_PLAN_CORE_JOBS $core_jobs

    set -l succeeded
    set -l failed
    set -l stop_starting 0
    set -l blocked 0
    set -l deferred
    set -l sudo_stopped 0
    set -l probe_stopped 0
    # Toolchain sanity-probe remediation (owner rule 2026-10-02): a failing
    # mid-run probe no longer aborts the dispatch — it FORCE-BUILDS the
    # at-risk chain (toolchain_remediation_plan) and refuses only if that
    # remediation build fails (or reconciles nothing). probe_remediating gates
    # dispatch to the remediation queue; the _REMED_* lists are globals so
    # pick_next_ready's force mode can order rebuilds against each other.
    set -l probe_remediating 0
    set -l remediation_phase ""
    set -g _REMED_PENDING
    set -g _REMED_ACTIVE
    set -g _REMED_ATTEMPTED
    # -i preflight: decide whether installs are possible BEFORE the first hour
    # of building is spent on packages that could never be installed. No prompt
    # belongs here or anywhere: every privilege escalation is `sudo -n`, so a
    # cold credential refuses the run immediately (the old code asked for a
    # password here; the 2026-09-26 decision is fail fast — rerun under
    # `sudo fish` or prime the credential with `sudo -v` first).
    set -l sudo_state up
    if test $install_flag -eq 1; and test "$_ROOT_MODE" != "1"
        switch (sudo_probe)
            case nopasswd
                # Nothing to keep warm: probing again would only be noise.
                set sudo_state nopasswd
            case cold
                set -g _RL_SUDO_NOTE "no install rights: nothing was built"
                ui_error "sudo cannot install non-interactively — refusing to start an -i run"
                echo "  Prefer 'sudo fish $SCRIPT_DIR/build-all.fish ...' for long runs: installs run as root and never expire."
                return 1
        end
    end
    set -l last_sudo (date +%s)
    set -l disp_count 0

    if not ensure_state_dirs
        return 1
    end
    # One run's sync/refresh notes: never carry the previous run's recipes
    # into this summary. Deleted by directory permission, so it works even
    # when an earlier root run left the file root-owned.
    rm -f -- "$_STATE_DIR/synced.list"
    printf '' >"$_STATE_DIR/synced.list" 2>/dev/null
    # Generate the makepkg dep-install shim at run start so every lane child
    # (lane_job re-checks and exports PACMAN) shares the builder mutex.
    if not ensure_pacman_shim
        ui_warning "could not generate $LOG_DIR/.pacman-shim — makepkg dep installs will not share the builder mutex"
    end
    set -g _ACTIVE_LANE_PIDS
    set -g _ACTIVE_LANE_PKGS
    set -l lane_busy
    set -l lane_pkg
    set -l lane_start
    set -l lane_pid
    for i in (seq $lanes)
        set -a lane_busy 0
        set -a lane_pkg ""
        set -a lane_start ""
        set -a lane_pid ""
    end
    set -g _DASHBOARD_LANE_BUSY $lane_busy
    set -g _DASHBOARD_LANE_PKG $lane_pkg
    set -g _DASHBOARD_LANE_START $lane_start
    set -g _DASHBOARD_SPINNER_INDEX 1
    set -g _DASHBOARD_LAST_EVENT "$_UI_ICON_INFO initializing"
    render_dashboard $total $disp_count 0 0 $stop_starting
    set -l last_status (date +%s)

    while true
        if test "$_INTERRUPT_HANDLED" = "1"
            cleanup_active_lanes
            abort_dashboard
            printf '\n'
            # Post-teardown lock probe: a lane's pacman may have died during
            # the cleanup TERM sweep — a provably-stale db.lck is removed
            # loudly here, a live holder is only reported.
            check_pacman_lock (pacman_db_lock_path)
            # Same aftermath window: a TERMed pacman may have died MID-COMMIT
            # (2026-09-24: mtree-only local entry, three packages' installs
            # poisoned until it was repaired). Idle → removed loudly here so
            # the next run's -i self-heals; busy → reported only.
            check_pacman_db_health (pacman_db_local_path)
            ui_warning "Build interrupted"
            dispatcher_log "Build interrupted (last signal: $_LAST_SIGNAL)"
            set -g _RL_INTERRUPTED 1
            return 130
        end

        # Reap finished lanes
        for i in (seq $lanes)
            if test $lane_busy[$i] -eq 1
                set -l rf "$LOG_DIR/.lane$i.result"
                set -l res_raw (cat "$rf" 2>/dev/null)
                set -l expected_pkg "$lane_pkg[$i]"
                set -l result_ready 0
                set -l result_malformed 0
                set -l decoded
                if test (count $res_raw) -gt 0
                    set decoded (lane_result_decode "$expected_pkg" "$res_raw[1]")
                    if test (count $decoded) -ge 3
                        set result_ready 1
                    else
                        set result_malformed 1
                    end
                end
                if test $result_ready -eq 0; and test $result_malformed -eq 0; and \
                    lane_pid_alive "$lane_pid[$i]"
                    # An absent or partial result is normal while the child
                    # is still running; atomic result publication prevents a
                    # finished child from looking partial here.
                    continue
                end
                if test $result_ready -eq 0; and test $result_malformed -eq 0; and \
                    not lane_pid_alive "$lane_pid[$i]"
                    # The read above and the death observed above are not one
                    # atomic step: a child can publish (write_lane_result's
                    # mv) and die BETWEEN them, which misreported an honest
                    # result as rc=125 "(no bytes)" (fixture flake, 2026-09-24).
                    # Publication happens-before death, so if the child wrote,
                    # the result exists NOW — re-read once. A genuinely
                    # missing write stays empty and falls through unchanged.
                    set res_raw (cat "$rf" 2>/dev/null)
                    if test (count $res_raw) -gt 0
                        set decoded (lane_result_decode "$expected_pkg" "$res_raw[1]")
                        if test (count $decoded) -ge 3
                            set result_ready 1
                        else
                            set result_malformed 1
                        end
                    end
                end

                set -l p "$expected_pkg"
                set -l rc $lane_outcome_lost
                set -l dur (math (date +%s) - $lane_start[$i])
                set -l wire_reason ""
                if test $result_ready -eq 1
                    # The codec's decode splits the wire line on newlines
                    # (fish command substitution splits on newlines only).
                    set p $decoded[1]
                    set rc $decoded[2]
                    set dur $decoded[3]
                    if test (count $decoded) -ge 4
                        set wire_reason $decoded[4]
                    end
                else
                    set -l log_file (package_log_file "$p")
                    # Reap forensics (2026-09-23: the raw symptom was a bare
                    # rc=125 with no evidence of what the lane was doing):
                    # name the lane's process state and show the result-file
                    # bytes exactly as seen, then mirror one line to
                    # dispatcher.log so the incident is self-describing.
                    set -l lane_state "(gone)"
                    if test -n "$lane_pid[$i]"
                        set lane_state (ps -o stat= -p "$lane_pid[$i]" 2>/dev/null | string trim)
                        test -n "$lane_state"; or set lane_state "(gone)"
                    end
                    set -l raw_joined "(no bytes)"
                    if test (count $res_raw) -gt 0
                        set raw_joined (string join ' | ' -- (string escape -- $res_raw))
                    end
                    # Best-effort forensics (mirrored to dispatcher.log
                    # below): settle log openability first — this append used
                    # to be the third "Permission denied" of the 2026-09-23
                    # incident when the lane's log was root-owned.
                    if ensure_log_writable "$log_file"
                        printf '%s\n' \
                            "$_UI_ICON_ERROR lane supervisor produced no valid result (pid=$lane_pid[$i], state=$lane_state)" \
                            "  result file bytes: $raw_joined" \
                            "  Check the lane log: $log_file" >>"$log_file"
                    end
                    dispatcher_log "reap anomaly pkg=$p pid=$lane_pid[$i] state=$lane_state reason=missing-or-malformed raw=$raw_joined"
                    set stop_starting 1
                    set -g _DASHBOARD_LAST_EVENT "$_UI_ICON_ERROR lane lost $p"
                end

                rm -f -- "$rf"
                set -l finished_pid $lane_pid[$i]
                set lane_busy[$i] 0
                set lane_pkg[$i] ""
                set lane_start[$i] ""
                set lane_pid[$i] ""
                if test -n "$finished_pid"
                    if test "$result_malformed" -eq 1
                        stop_lane_process "$finished_pid" malformed "$p"
                    else
                        wait "$finished_pid" 2>/dev/null
                    end
                    forget_lane_pid "$finished_pid"
                end

                set -a _lane_done $p
                # Toolchain remediation bookkeeping (2026-10-02): a
                # force-built remediation package's outcome decides the
                # remediation, not the run — track its reap before the
                # classification switch dispatches on it.
                set -l is_remediation 0
                if test $probe_remediating -eq 1; and test (count $_REMED_ACTIVE) -gt 0; and contains "$p" $_REMED_ACTIVE
                    set is_remediation 1
                    set -e _REMED_ACTIVE[(contains --index -- "$p" $_REMED_ACTIVE)]
                    set -a _REMED_ATTEMPTED "$p"
                end
                # Classify through the lane_outcome_* vocabulary — one switch
                # on the codec's rc: the enum names decide, the wire's raw
                # number never leaks a decision. The default carries every
                # non-success outcome (failed, lost, signal-*) down the same
                # failure contract.
                switch (lane_outcome_name $rc)
                    case ok
                        set -a succeeded $p
                        run_record_row "$p" succeeded 0 $dur ok
                        set -g _DASHBOARD_LAST_EVENT "$_UI_ICON_OK completed $p"
                        # Mid-run ABI-skew probe (2026-09-25 incident): the
                        # preflight passed at run START, and this run's own
                        # llvm install can break the system rustc after that.
                        # Re-probe after a successful -i lane for llvm-git /
                        # llvm-libs-git, BEFORE anything else dispatches.
                        # Failure is a real ABI mismatch — even
                        # --allow-broken-rustc is documented as "not a way
                        # past" one — but since the 2026-10-02 owner rule it
                        # takes the REMEDIATION contract, not the stop-dispatch
                        # one: FORCE-BUILD the at-risk chain (first rust-git,
                        # or the whole core group when the broken consumer
                        # cannot be identified narrowly) and refuse only when
                        # that remediation build fails too. The probe stays
                        # loud; it no longer refuses builds while remediation
                        # is possible. Once per remediation cycle, not per
                        # package (a remediation re-install re-probes through
                        # the completion path below, never re-triggers here).
                        if test $install_flag -eq 1; and test $probe_stopped -eq 0; and test $probe_remediating -eq 0
                            if contains "$p" llvm-git llvm-libs-git
                                if not check_rustc_sanity
                                    ui_error "rustc sanity probe failed after $p was installed — this run's own llvm install broke rustc"
                                    echo "  Toolchain risk detected for the tool-clang/llvm consumer chain — not"
                                    echo "  just rustc. Owner rule 2026-10-02: the builder FORCE-BUILDS the at-risk"
                                    echo "  chain to reconcile it — first rust-git (rust), or the whole core group"
                                    echo "  when the broken consumer cannot be identified narrowly — and refuses"
                                    echo "  only if that remediation build also fails. This probe stays loud but"
                                    echo "  does not refuse builds while remediation is possible."
                                    set -l plan (toolchain_remediation_plan "$p" rust-git)
                                    set -l plan_kind ""
                                    set -l plan_chain
                                    if test (count $plan) -ge 2
                                        set plan_kind $plan[1]
                                        set plan_chain $plan[2..-1]
                                    end
                                    if test (count $plan_chain) -eq 0
                                        ui_error "no force-build remediation chain is identifiable for $p — refusing to continue"
                                        probe_refusal_text
                                        set probe_stopped 1
                                        set stop_starting 1
                                        set -g _DASHBOARD_LAST_EVENT "$_UI_ICON_ERROR rustc probe failed after $p"
                                    else
                                        set probe_remediating 1
                                        set remediation_phase $plan_kind
                                        set _REMED_PENDING $plan_chain
                                        set _REMED_ACTIVE
                                        set _REMED_ATTEMPTED
                                        set total (math $total + (force_queue_packages $_REMED_PENDING))
                                        ui_warning "toolchain remediation (phase $remediation_phase): force-building "(string join ', ' $_REMED_PENDING)" to reconcile the at-risk chain before anything else compiles"
                                        set -g _DASHBOARD_LAST_EVENT "$_UI_ICON_WARN toolchain remediation: rebuild $plan_chain"
                                    end
                                end
                            end
                        end
                        # Remediation completion: the whole force-built chain
                        # has landed — re-probe. Pass: reconciled, resume
                        # dispatch. Still failing after the narrow consumer:
                        # escalate to the whole core group (the general
                        # tool-clang/llvm consumer chain, not just rustc).
                        # Still failing after that, or a failed remediation
                        # build: the refusal contract.
                        if test $is_remediation -eq 1; and test (count $_REMED_PENDING) -eq 0; and test (count $_REMED_ACTIVE) -eq 0
                            if check_rustc_sanity
                                ui_success "toolchain remediation reconciled the at-risk chain (rebuilt "(string join ', ' $_REMED_ATTEMPTED)") — rustc sanity probe passes, resuming dispatch"
                                set probe_remediating 0
                                set remediation_phase ""
                                set _REMED_ATTEMPTED
                            else if test "$remediation_phase" = narrow
                                ui_error "remediation by "(string join ', ' $_REMED_ATTEMPTED)" was insufficient — the tool-clang/llvm consumer chain is still broken"
                                echo "  Escalating to a full core-group force-build (owner rule 2026-10-02)."
                                set remediation_phase core
                                set _REMED_PENDING
                                for rp in $_GROUP_core
                                    if not contains "$rp" $_REMED_ATTEMPTED
                                        set -a _REMED_PENDING "$rp"
                                    end
                                end
                                if test (count $_REMED_PENDING) -eq 0
                                    ui_error "core-group remediation has nothing left to force-build — refusing to continue"
                                    probe_refusal_text
                                    set probe_stopped 1
                                    set stop_starting 1
                                    set -g _DASHBOARD_LAST_EVENT "$_UI_ICON_ERROR toolchain remediation exhausted after $p"
                                else
                                    set total (math $total + (force_queue_packages $_REMED_PENDING))
                                    ui_warning "toolchain remediation (phase core): force-building "(string join ', ' $_REMED_PENDING)
                                    set -g _DASHBOARD_LAST_EVENT "$_UI_ICON_WARN toolchain remediation: core rebuild $_REMED_PENDING"
                                end
                            else
                                ui_error "core-group remediation rebuilt "(string join ', ' $_REMED_ATTEMPTED)" and the sanity probe still fails — refusing to continue"
                                probe_refusal_text
                                set probe_stopped 1
                                set stop_starting 1
                                set -g _DASHBOARD_LAST_EVENT "$_UI_ICON_ERROR toolchain remediation failed after $p"
                            end
                        end
                    case defer
                        # The lane parked the recipe — anchoring refused, or
                        # the -s freshness refusal when upstream never
                        # answered (wire reason; legacy 3-field results keep
                        # the anchoring default): NOT a failed build. Dispatch
                        # keeps going; dependents of $p are held back by
                        # pick_next_ready; $p stays out of succeeded+failed so
                        # it lands in the resume command.
                        set -a deferred $p
                        set -a _lane_deferred $p
                        set -l row_reason "$wire_reason"
                        if test -z "$row_reason"
                            set row_reason anchoring-refused
                        end
                        run_record_row "$p" deferred $rc $dur $row_reason
                        set -g _DASHBOARD_LAST_EVENT "$_UI_ICON_WARN deferred $p"
                        # A parked remediation build cannot reconcile anything
                        # (2026-10-02): remediation failed ⇒ the refusal contract.
                        if test $is_remediation -eq 1
                            ui_error "toolchain remediation build for $p was deferred — the at-risk chain cannot be reconciled; refusing to continue"
                            probe_refusal_text
                            set probe_stopped 1
                            set stop_starting 1
                            set -g _DASHBOARD_LAST_EVENT "$_UI_ICON_ERROR remediation deferred $p"
                        end
                    case '*'
                        set -a failed $p
                        set stop_starting 1
                        # A reaped row exists for an honest lane result; a reap
                        # anomaly (lane_outcome_lost, no valid result) is the
                        # lane being lost.
                        if test "$result_ready" = "1"
                            run_record_row "$p" failed $rc $dur build-failed
                        else
                            run_record_row "$p" failed $rc $dur lane-lost
                        end
                        if test "$result_ready" = "1"
                            set -g _DASHBOARD_LAST_EVENT "$_UI_ICON_ERROR failed $p"
                        end
                        # A failed remediation build is the one refusal left
                        # (owner rule 2026-10-02): refuse and drain — the probe
                        # failure alone never does.
                        if test $is_remediation -eq 1
                            ui_error "toolchain remediation build for $p failed — the at-risk chain could not be reconciled; refusing to continue"
                            probe_refusal_text
                            set probe_stopped 1
                            set -g _DASHBOARD_LAST_EVENT "$_UI_ICON_ERROR remediation failed $p"
                        end
                end
                set -g _DASHBOARD_LANE_BUSY $lane_busy
                set -g _DASHBOARD_LANE_PKG $lane_pkg
                set -g _DASHBOARD_LANE_START $lane_start
                render_dashboard $total $disp_count (count $succeeded) (count $failed) $stop_starting
                if test "$_OUTPUT_INTERACTIVE" != "1"
                    switch (lane_outcome_name $rc)
                        case ok
                            printf "  %s %s (%s)\n" "$_UI_ICON_OK" $p (fmt_dur $dur)
                        case defer
                            # The named error and its recovery lines live in the
                            # log; the run summary tails it — this line only has
                            # to park the recipe visibly without breaking pipes.
                            set -l why (run_record_field "$p" reason)
                            if test -z "$why"
                                set why anchoring-refused
                            end
                            printf "  %s %s: DEFERRED (%s) — log: %s\n" \
                                "$_UI_ICON_WARN" $p "$why" (package_log_file "$p")
                        case '*'
                            set -l log_file (package_log_file "$p")
                            printf "  %s %s: BUILD FAILED (rc=%s, %s) — log: %s\n" \
                                "$_UI_ICON_ERROR" $p $rc (fmt_dur $dur) "$log_file"
                            ui_warning "Last lines:"
                            print_log_tail "$log_file"
                            if test $install_flag -eq 1
                                ui_warning "(with -i the failure may be the INSTALL, not the build — check the log tail above; if the archive exists, install later with -ia or resume with -s -i)"
                            end
                    end
                end
            end
        end

        # Keep the sudo credential warm so background installs never need a
        # password (escalation is `sudo -n` and never prompts; lane children
        # have no tty). Root mode needs none of this — installs are direct
        # pacman calls.
        if test $install_flag -eq 1; and test "$_ROOT_MODE" != "1"; and test "$sudo_state" = up
            set -l now (date +%s)
            if test (math $now - $last_sudo) -gt $_SUDO_KEEPALIVE_S
                switch (sudo_probe)
                    case fresh
                        set last_sudo $now
                    case nopasswd
                        # `-v` will never be permitted here, yet every install
                        # succeeds: stop probing rather than re-deciding this
                        # every interval.
                        set sudo_state nopasswd
                        set -g _DASHBOARD_LAST_EVENT "$_UI_ICON_INFO sudo: installs need no password"
                    case cold
                        abort_dashboard
                        # Latch: every later probe would fail and re-print.
                        # Say it ONCE, stop dispatch, and let in-flight lanes
                        # finish (their own installs fail fast, no hang).
                        # Never prompt: escalation is `sudo -n` only.
                        set sudo_state down
                        if test (count $_lane_started) -lt $total
                            set sudo_stopped 1
                            set -g _RL_SUDO_NOTE "sudo credential lost: some packages were never started"
                        end
                        ui_error "sudo credential expired and cannot be refreshed — stopping dispatch"
                        echo "  Install later with 'build-all.fish -ia', or resume with 'build-all.fish -s -i'."
                        set stop_starting 1
                end
            end
        end

        if test "$_INTERRUPT_HANDLED" = "1"
            continue
        end

        # Dispatch to idle lanes
        if test $stop_starting -eq 0
            for i in (seq $lanes)
                if test $lane_busy[$i] -eq 1
                    continue
                end
                # Toolchain remediation gates dispatch (2026-10-02): while the
                # force queue is being rebuilt, ONLY its targets start — they
                # must reconcile the system before anything else compiles
                # against it — and with an empty queue every lane waits for
                # the in-flight remediation to land. Non-remediation work is
                # held back, never refused.
                set -l restrict
                if test $probe_remediating -eq 1
                    set restrict $_REMED_PENDING
                    if test (count $restrict) -eq 0
                        continue
                    end
                end
                set -l other_busy 0
                set -l other_solo 0
                for j in (seq $lanes)
                    if test $j -ne $i; and test $lane_busy[$j] -eq 1
                        set other_busy 1
                        if contains "$lane_pkg[$j]" $_GROUP_core
                            set other_solo 1
                        end
                    end
                end
                # A running core build is SOLO: never start anything alongside
                # it (its full -j implies peak RAM; pairing defeats the guard)
                if test $other_solo -eq 1
                    continue
                end
                # Core = solo: needs every lane idle; otherwise fall back to
                # the first ready NON-core package so nothing idles needlessly.
                set -l next (pick_next_ready 1 $restrict)
                if test -n "$next"; and contains "$next" $_GROUP_core; and test $other_busy -eq 1
                    set next (pick_next_ready 0 $restrict)
                end
                if test -z "$next"
                    continue
                end
                set -l jobs $lane_jobs
                if contains "$next" $_GROUP_core
                    set jobs $core_jobs
                end
                set -l rf "$LOG_DIR/.lane$i.result"
                set -l child_log (package_log_file "$next")
                # Settle log ownership/openability BEFORE the lane exists.
                # A poisoned log used to die here — the spawn redirect failed
                # and surfaced later as a bogus "BUILD FAILED (rc=125, 0m00s)"
                # with the build never started (2026-09-23). Failure names
                # the file and stops dispatch; counting it in failed[] makes
                # run_lanes return non-zero (its stop contract).
                if not ensure_log_writable "$child_log"
                    ui_error "cannot prepare build log for $next — stopped dispatching"
                    set -a failed $next
                    run_record_row "$next" failed 1 0 log-unwritable
                    set stop_starting 1
                    continue
                end
                set -a _lane_started $next
                set lane_busy[$i] 1
                set lane_pkg[$i] $next
                set lane_start[$i] (date +%s)
                rm -f "$rf"
                # Clear before the child starts preflight/sync so the
                # dashboard never shows a previous run's tail for this lane.
                printf '' >"$child_log"
                set disp_count (math $disp_count + 1)
                # Fish executes a backgrounded function synchronously. Invoke
                # the hidden child mode as an external fish process so this
                # dispatch loop can continue filling idle lanes immediately.
                # Capture the complete child process boundary, not only the
                # makepkg call, so hooks/signals can never corrupt the dashboard.
                # The payload shape is lane_argv's (the handler validates the
                # same description via lane_argv_check). A remediation
                # FORCE-build (2026-10-02) reconciles the system NOW: it may
                # not freshness-skip under -s and its install may not be
                # same-version-refused — the existing skip/force lane flags
                # express both overrides; no new lane machinery.
                set -l lane_skip $skip_flag
                set -l lane_force_install $force_install_flag
                if test $probe_remediating -eq 1; and contains "$next" $_REMED_PENDING
                    set lane_skip 0
                    set lane_force_install 1
                    set -e _REMED_PENDING[(contains --index -- "$next" $_REMED_PENDING)]
                    set -a _REMED_ACTIVE "$next"
                end
                setsid --wait fish "$SCRIPT_DIR/build-all.fish" --lane-job \
                    (lane_argv "$next" "$rf" $jobs $install_flag $clean_flag \
                        $lane_skip $no_sync_flag $lane_force_install) >>"$child_log" 2>&1 &
                set lane_pid[$i] $last_pid
                set -a _ACTIVE_LANE_PIDS $last_pid
                set -a _ACTIVE_LANE_PKGS $next
                set -g _DASHBOARD_LANE_BUSY $lane_busy
                set -g _DASHBOARD_LANE_PKG $lane_pkg
                set -g _DASHBOARD_LANE_START $lane_start
                set -g _DASHBOARD_LAST_EVENT "$_UI_ICON_ACTIVE started $next on lane $i"
                render_dashboard $total $disp_count (count $succeeded) (count $failed) $stop_starting
                if test "$_OUTPUT_INTERACTIVE" != "1"
                    printf "  [lane %d] %s (%d/%d, -j%d)\n" $i $next $disp_count $total $jobs
                end
            end
        end

        # Termination: nothing running and (stopped on failure, or everything
        # started has been reaped). Packages that never became ready (cycle /
        # missing dep — topo_sort appends those at the end) are reported here.
        set -l active 0
        for i in (seq $lanes)
            if test $lane_busy[$i] -eq 1
                set active (math $active + 1)
            end
        end
        if test $active -eq 0
            # Remediation stalled: its force queue is non-empty but nothing
            # dispatched (unmet dependency inside the queue). That is a failed
            # remediation as far as the owner rule is concerned — refuse.
            if test $probe_remediating -eq 1; and test (count $_REMED_PENDING) -gt 0
                ui_error "toolchain remediation stalled — "(string join ', ' $_REMED_PENDING)" cannot be dispatched; refusing to continue"
                probe_refusal_text
                set probe_stopped 1
                set stop_starting 1
                set -g _DASHBOARD_LAST_EVENT "$_UI_ICON_ERROR remediation stalled"
            end
            if test $stop_starting -eq 1
                break
            end
            if test (count $_lane_started) -eq (count $_lane_done)
                set -l unstarted (math $total - (count $_lane_started))
                if test $unstarted -gt 0
                    set blocked $unstarted
                    abort_dashboard
                    # Honest labels: a package whose dependency was DEFERRED
                    # waited on a parked recipe, not on a cycle (2026-09-24).
                    set -l waiting 0
                    for pkg in $_lane_sorted
                        if not contains "$pkg" $_lane_started
                            if waits_on_deferred $pkg
                                set waiting (math $waiting + 1)
                            end
                        end
                    end
                    if test $waiting -gt 0
                        ui_warning "$unstarted package(s) not dispatched ($waiting wait on a deferred recipe) — skipped:"
                    else
                        ui_warning "$unstarted package(s) never became ready (dependency cycle or missing dep) — skipped:"
                    end
                    for pkg in $_lane_sorted
                        if not contains "$pkg" $_lane_started
                            if waits_on_deferred $pkg
                                run_record_row "$pkg" blocked - - waits-on-deferred
                                echo "    ⏸ $pkg — waits on a deferred package"
                            else
                                run_record_row "$pkg" blocked - - never-ready
                                echo "    ? $pkg"
                            end
                        end
                    end
                end
                break
            end
        end

        # Live status (multi-lane only): the interactive path redraws the
        # dashboard; pipes get plain append-only records.
        if test $lanes -gt 1 -a $active -gt 1
            set -l now (date +%s)
            if test (math $now - $last_status) -ge 10
                set -l parts
                for i in (seq $lanes)
                    if test $lane_busy[$i] -eq 1 -a -n "$lane_start[$i]"
                        set -l lane_name (basename "$lane_pkg[$i]")
                        set -l elapsed_fmt (fmt_dur (math $now - $lane_start[$i]))
                        set -a parts "lane $i: $lane_name ($elapsed_fmt)"
                    end
                end
                if test (count $parts) -gt 0
                    if test "$_OUTPUT_INTERACTIVE" = "1"
                        set -g _DASHBOARD_LANE_BUSY $lane_busy
                        set -g _DASHBOARD_LANE_PKG $lane_pkg
                        set -g _DASHBOARD_LANE_START $lane_start
                        set -g _DASHBOARD_LAST_EVENT "status update"
                        render_dashboard $total $disp_count (count $succeeded) (count $failed) $stop_starting
                    else
                        printf "  STATUS: %s\n" (string join " | " $parts)
                    end
                    set last_status $now
                end
            end
        end

        # Keep the interactive dashboard alive while a package is quiet:
        # refresh tails and advance the event spinner on every dispatcher poll.
        if test "$_OUTPUT_INTERACTIVE" = "1"; and test $active -gt 0
            set -g _DASHBOARD_SPINNER_INDEX (math "$_DASHBOARD_SPINNER_INDEX % 4 + 1")
            set -g _DASHBOARD_LANE_BUSY $lane_busy
            set -g _DASHBOARD_LANE_PKG $lane_pkg
            set -g _DASHBOARD_LANE_START $lane_start
            render_dashboard $total $disp_count (count $succeeded) (count $failed) $stop_starting
        end

        sleep 0.5
    end

    finish_dashboard
    if test "$_OUTPUT_INTERACTIVE" = "1"; and test (count $failed) -gt 0
        for i in (seq (count $failed))
            set -l p $failed[$i]
            set -l rc (run_record_field $p rc)
            set -l dur (run_record_field $p dur)
            set -l log_file (package_log_file "$p")
            printf "  %s %s: BUILD FAILED (rc=%s, %s) — log: %s\n" \
                "$_UI_ICON_ERROR" $p $rc (fmt_dur $dur) "$log_file"
            ui_warning "Last lines:"
            print_log_tail "$log_file"
            if test $install_flag -eq 1
                ui_warning "(with -i the failure may be the INSTALL, not the build — check the log tail above; if the archive exists, install later with -ia or resume with -s -i)"
            end
        end
    end
    if test "$_OUTPUT_INTERACTIVE" = "1"; and test (count $deferred) -gt 0
        for p in $deferred
            set -l why (run_record_field "$p" reason)
            if test -z "$why"
                set why anchoring-refused
            end
            printf "  %s %s: DEFERRED (%s) — log: %s\n" \
                "$_UI_ICON_WARN" $p "$why" (package_log_file "$p")
        end
    end

    # The run record is completed by run_record_finalize (called once by main
    # after run_lanes returns, on every terminal path) — it derives the
    # exported _RL_* results from the rows instead of maintaining them here.
    # A dispatch stopped by a lost sudo credential left packages unbuilt: that
    # must never be reported as "All builds succeeded!" (2026-09-17). Nor may
    # a run that parked a recipe — parked work needs the owner (2026-09-24).
    if test (count $failed) -gt 0 -o "$blocked" -gt 0; or test "$sudo_stopped" -eq 1; or test "$probe_stopped" -eq 1
        return 1
    end
    if test (count $deferred) -gt 0
        return 1
    end
    return 0
end

# ─── Run record & continuation ──────────────────────────────────────────────
# ONE "run plan & outcome" record per run. run_lanes' classification is the
# single writer (run_record_row at every outcome), run_record_plan registers
# the plan once before dispatch, run_record_finalize completes the record once
# on every terminal path (called by main right after run_lanes returns), and
# exactly three renderings consume it: the streaming dashboard (live, from the
# same classification), the prose summary (print_run_summary) and the machine
# block (print_run_record).
#
# The dispatcher→main handoff is internal plumbing of this cluster now. The
# exported names (_RL_SUCCEEDED / _RL_FAILED / _RL_BLOCKED / _RL_DEFERRED /
# _RL_SUDO_NOTE) keep working, but they are DERIVED from the rows instead of
# being maintained in parallel with them.
#
# Row grammar (internal): pkg|status|rc|dur|reason — exactly one row per
# package, in topological order after finalize. status ∈ {succeeded, failed,
# deferred, blocked, never-started, interrupted} ("deferred" NAMES the lane
# rc-99 _ANCHOR_DEFER_RC amendment: a parked recipe, not a failed build —
# either anchoring refusal or a named freshness refusal; the reason token
# says which). rc and dur are integers (dur in seconds) or '-' when
# the package never produced one. reason is a kebab-case token:
#   ok                   succeeded
#   build-failed         lane ran, makepkg/exits non-zero (rc is in the row)
#   lane-lost            reap anomaly: no valid lane result (rc=125)
#   log-unwritable       dispatch refused: the package log could not be opened
#   anchoring-refused    deferred (rc=99): checksum anchoring refused
#   upstream-unverified  deferred (rc=99): -s could not confirm the recorded
#                        refs against upstream after transport retries
#   waits-on-deferred    blocked on a parked recipe
#   never-ready          blocked: dependency cycle or missing dep
#   dispatch-stopped     never started: dispatch stopped, lanes drained
#   preflight-refused    never started: the run refused before dispatching
#   interrupted-before-start  never started: the run was interrupted first
#   interrupted-mid-build     started, in flight when the run was interrupted

function run_record_row -a r_pkg r_status r_rc r_dur r_reason
    # NB: no parameter may be named `status`/`pipestatus`/etc. — fish reserves
    # those, and a definition using them fails with "variable is read-only",
    # leaving the function silently undefined (cost an hour, 2026-09-26).
    set -a _RL_ROWS "$r_pkg|$r_status|$r_rc|$r_dur|$r_reason"
end

# One field of one package's row (status/rc/dur/reason); empty when the
# package has no row yet.
function run_record_field -a pkg field
    for row in $_RL_ROWS
        set -l f (string split '|' -- "$row")
        if test "$f[1]" = "$pkg"
            switch $field
                case status
                    echo "$f[2]"
                case rc
                    echo "$f[3]"
                case dur
                    echo "$f[4]"
                case reason
                    echo "$f[5]"
            end
            return 0
        end
    end
    return 1
end

# Register the run's plan once, before dispatch. The 9 fixed arguments are the
# continuation state (mirrored by continuation_args) plus the selection-source
# scalar; the payload is the topological order of the selection.
function run_record_plan -a lanes jobs intensity install force no_deps no_sync allow_broken source
    set -g _RL_ROWS
    set -g _RL_REMAINING
    set -g _RL_SUCCEEDED
    set -g _RL_FAILED
    set -g _RL_DEFERRED
    set -g _RL_BLOCKED 0
    set -g _RL_SUDO_NOTE ""
    set -g _RL_INTERRUPTED 0
    set -g _RR_SOURCE "$source"
    set -g _RR_ORDER $argv[10..-1]
    set -g _RR_CONT_LANES "$lanes"
    set -g _RR_CONT_JOBS "$jobs"
    set -g _RR_CONT_INTENSITY "$intensity"
    set -g _RR_CONT_INSTALL "$install"
    set -g _RR_CONT_FORCE "$force"
    set -g _RR_CONT_NO_DEPS "$no_deps"
    set -g _RR_CONT_NO_SYNC "$no_sync"
    set -g _RR_CONT_ALLOW_BROKEN "$allow_broken"
    # Resolved by run_lanes once the plan is computed (the `parallelism:` line
    # knows them); '-' until then — a run that refused before planning has no
    # resolved values to report.
    set -g _RL_PLAN_LANES -
    set -g _RL_PLAN_NORMAL_JOBS -
    set -g _RL_PLAN_CORE_JOBS -
end

# Complete the record once, after run_lanes returned on any path. Packages the
# dispatcher never classified get their honest terminal row: started but
# unrowed can only mean the interrupt drained them mid-build; the rest were
# never dispatched (why is data: interrupted / dispatch-stopped /
# preflight-refused). Then the rows are put in topological order and the
# exported results and the Remaining set (failed + unattempted, topological
# order — a failed package must rebuild BEFORE its dependents, so it stays in
# Remaining and in the resume suggestion) are derived from them.
function run_record_finalize
    set -l rowed
    for row in $_RL_ROWS
        set -a rowed (string split -f 1 '|' -- "$row")
    end
    # One reason for ALL never-started rows, decided from the state as
    # finalize found it — not per row, which would let the first row added by
    # this very loop flip the rest from preflight-refused to dispatch-stopped.
    set -l ns_reason dispatch-stopped
    if test "$_RL_INTERRUPTED" = "1"
        set ns_reason interrupted-before-start
    else if test (count $_lane_started) -eq 0; and test (count $_RL_ROWS) -eq 0
        set ns_reason preflight-refused
    end
    for pkg in $_RR_ORDER
        if contains "$pkg" $rowed
            continue
        end
        if test (count $_lane_started) -gt 0; and contains "$pkg" $_lane_started
            run_record_row "$pkg" interrupted - - interrupted-mid-build
        else
            run_record_row "$pkg" never-started - - $ns_reason
        end
    end
    set -l ordered
    for pkg in $_RR_ORDER
        for row in $_RL_ROWS
            if test (string split -f 1 '|' -- "$row") = "$pkg"
                set -a ordered $row
                break
            end
        end
    end
    set _RL_ROWS $ordered

    set -g _RL_SUCCEEDED
    set -g _RL_FAILED
    set -g _RL_DEFERRED
    set -g _RL_REMAINING
    set -l blocked_rows 0
    for row in $_RL_ROWS
        set -l f (string split '|' -- "$row")
        switch $f[2]
            case succeeded
                set -a _RL_SUCCEEDED $f[1]
            case failed
                set -a _RL_FAILED $f[1]
            case deferred
                set -a _RL_DEFERRED $f[1]
            case blocked
                set blocked_rows (math $blocked_rows + 1)
        end
        if test "$f[2]" != succeeded
            set -a _RL_REMAINING $f[1]
        end
    end
    set -g _RL_BLOCKED $blocked_rows
end

# ─── continuation_args: ONE implementation of both continuation mirrors ──────
# The canonical flag → continuation-rule table. continuation_args iterates it
# (the list order below IS the emission order) and every continuation command
# the builder prints is rendered from it. The two mirrors are the SAME
# function; they differ only in mode:
#
#   replay — the sudo rerun hint: canonical plan-triple + install flavour, then
#            the raw argv replay (so semantics/replaced/ignored flags ride
#            along in their original spelling). Prefix:
#            `sudo fish $SCRIPT_DIR/build-all.fish`.
#   resume — the resume suggestion: canonical plan-triple + install flavour +
#            semantics flags + the $remaining package list (selection
#            replaced). Prefix: bare `build-all.fish`.
#
#   rule        flag(s)                              continuation treatment
#   value       --lanes --jobs --intensity           mirrored with their value
#   flavour     -i --install -fi --forceinstall      -i → --install; -fi →
#                                                   --forceinstall (implies -i)
#   semantics   --no-deps --no-sync                  mirrored on resume only
#               --allow-broken-rustc                 (replay carries argv)
#   replaced    -g/--group, N..M ranges,             replaced by the package
#               package references                  list ($remaining/argv)
#   not-mirrored -c/--clean, -s/--skip               deliberately NOT mirrored:
#                                                   -c would wipe the archives
#                                                   a resume needs, and -s is
#                                                   the user's call (the tip
#                                                   says to add it)
#   not-mirrored -n -l -ia -cc -ccc -ln              one-shot actions and
#               --audit -h --help                    read-only modes
set -g _CONTINUATION_RULES \
    '--lanes|value' \
    '--jobs|value' \
    '--intensity|value' \
    '-i --install -fi --forceinstall|flavour' \
    '--no-deps|semantics' \
    '--no-sync|semantics' \
    '--allow-broken-rustc|semantics' \
    '-g --group, N..M ranges, package references|replaced' \
    '-c --clean|not-mirrored' \
    '-s --skip|not-mirrored' \
    '-n --dry-run -l --list -ia --installall -cc --cleanup -ccc --nuclear -ln --link-sources --audit -h --help|not-mirrored'

# continuation_args MODE [PAYLOAD...] → one line of continuation arguments.
# Run-shape state comes from the run record (run_record_plan).
function continuation_args -a mode
    set -l payload $argv[2..-1]
    set -l out
    for entry in $_CONTINUATION_RULES
        set -l fields (string split '|' -- $entry)
        set -l flag $fields[1]
        switch $fields[2]
            case value
                switch $flag
                    case --lanes
                        set -a out --lanes "$_RR_CONT_LANES"
                    case --jobs
                        set -a out --jobs "$_RR_CONT_JOBS"
                    case --intensity
                        set -a out --intensity "$_RR_CONT_INTENSITY"
                end
            case flavour
                # -fi implies -i, so one flag preserves both halves of the
                # semantics; a plain -i keeps its same-version check.
                if test "$_RR_CONT_FORCE" = "1"
                    set -a out --forceinstall
                else if test "$_RR_CONT_INSTALL" = "1"
                    set -a out --install
                end
            case semantics
                # Resume only: replay carries these inside the argv replay.
                if test "$mode" = resume
                    switch $flag
                        case --no-deps
                            if test "$_RR_CONT_NO_DEPS" = "1"
                                set -a out --no-deps
                            end
                        case --no-sync
                            if test "$_RR_CONT_NO_SYNC" = "1"
                                set -a out --no-sync
                            end
                        case --allow-broken-rustc
                            if test "$_RR_CONT_ALLOW_BROKEN" = "1"
                                set -a out --allow-broken-rustc
                            end
                    end
                end
        end
    end
    string join ' ' -- $out $payload
end

# The prose summary. Success and failure renderings are byte-stable prose; an
# interrupted run reuses the failure body under its own "Build interrupted"
# heading (printed by the interrupt path itself).
function print_run_summary -a outcome
    set -l succeeded $_RL_SUCCEEDED
    set -l failed $_RL_FAILED
    set -l deferred $_RL_DEFERRED
    set -l remaining $_RL_REMAINING
    set -l blocked $_RL_BLOCKED
    set -l sudo_note "$_RL_SUDO_NOTE"

    if test "$outcome" = success
        ui_heading "All builds succeeded!"
        echo "Built: "(count $succeeded)" packages"
    else
        if test "$outcome" = failed
            # Failure summary — dispatch stopped on first failure and in-flight
            # lanes were drained, so anything unstarted is genuinely pending.
            # With -i everything built so far is ALREADY installed (resume with
            # -s -i). A DEFERRAL is the deliberate exception (2026-09-24): an
            # unanchorable recipe parks itself and the dispatch CONTINUES, so
            # this summary must not claim a stop that never happened — it names
            # the parked recipes instead.
            if test (count $failed) -gt 0
                ui_error "Build failed — stopped dispatching, drained in-flight lanes."
            else if test "$blocked" -eq 0; and test (count $deferred) -eq 0; and test -n "$sudo_note"
                ui_warning "Stopped early — $sudo_note."
            else if test (count $deferred) -gt 0
                ui_warning "(count $deferred) recipe(s) deferred — the rest of the dispatch continued; the parked recipes below were not built."
                if test -n "$sudo_note"
                    ui_warning "Stopped early — $sudo_note."
                end
            else
                ui_error "Build failed — stopped dispatching, drained in-flight lanes."
            end
        end
        echo ""
        echo "Successful builds: "(count $succeeded)
        echo "Failed builds:     "(count $failed)
        echo "Blocked:           $blocked"
        echo "Deferred:          "(count $deferred)
        echo "Remaining:         "(count $remaining)
        if test (count $failed) -gt 0
            echo "note: "(count $failed)" failed package(s) included — they must rebuild before their dependents"
        end
        if test (count $deferred) -gt 0
            echo ""
            echo "Deferred recipes (not built — the log tail says why):"
            for p in $deferred
                echo "  $p"
                print_log_tail (package_log_file "$p")
            end
        end
        if test (count $remaining) -gt 0
            echo ""
            echo "To resume, run:"
            echo "  build-all.fish "(continuation_args resume $remaining)""
            echo "(Tip: add -s so already-built pkgs are skipped.)"
        end
    end

    # Ambient-knob gap (2026-09-26): GSA_TARGET_CPU and GSA_STATE_DIR are
    # ENVIRONMENT inputs — never baked into a continuation command — so a
    # continuation must run with the same ambient values as this run.
    set -l ambient
    set -q GSA_TARGET_CPU; and set -a ambient GSA_TARGET_CPU
    set -q GSA_STATE_DIR; and set -a ambient GSA_STATE_DIR
    if test (count $ambient) -gt 0
        ui_warning "ambient environment: "(string join ' ' $ambient)" — the continuation must run in the same env (never baked into the command)"
    end
end

# The machine block (C8): one bounded end-of-run record on stdout, default-on.
# Stable markers; `key: value` plan scalars; one row per package
# (`pkg status rc dur reason`, space-separated, reason is the remainder of the
# line). Full rows, never exceptions-only. Printed only after the dashboard is
# finished (finish_dashboard / abort_dashboard) so its ANSI renderer can never
# garble the block — and on the interrupt and sudo-preflight paths too.
function print_run_record -a outcome run_rc
    echo "--- run record begin ---"
    echo "format: 1"
    echo "selection-source: $_RR_SOURCE"
    echo "order: "(string join ' ' -- $_RR_ORDER)
    echo "lanes: $_RL_PLAN_LANES"
    echo "normal-jobs: $_RL_PLAN_NORMAL_JOBS"
    echo "core-jobs: $_RL_PLAN_CORE_JOBS"
    echo "intensity: $_RR_CONT_INTENSITY"
    echo "outcome: $outcome"
    echo "rc: $run_rc"
    for row in $_RL_ROWS
        echo (string join ' ' -- (string split '|' -- "$row"))
    end
    echo "--- run record end ---"
end

# ─── Usage ───────────────────────────────────────────────────────────────────
# --topology: the resolved topology as machine-readable records. One line per
# package in map order, ALWAYS five pipe fields:
#   id|path|groups|edges|tags
# (comma-joined fields; empty = none). This is the data channel for
# tests/srcinfo-freshness.sh and the per-recipe registration fixtures: they
# consume THIS instead of parsing config/ themselves — one reader, one truth.
# Read-only: load_project_config has already validated every record.
function print_topology
    echo "# id|path|groups|edges|tags"
    for entry in $_PACKAGE_MAP
        set -l fields (string split '|' -- "$entry")
        set -l id "$fields[1]"
        set -l group_values
        for group_name in $_GROUP_NAMES
            set -l mangled (string replace - _ -- "$group_name")
            set -l var_name "_GROUP_$mangled"
            if contains "$id" $$var_name
                set -a group_values "$group_name"
            end
        end
        set -l edge_values (deps_of $id)
        set -l tag_values
        # Raw record tags, comma-joined in record order: the data channel
        # round-trips every tag (app-cluster=<name> included) unchanged. The
        # vocabulary is closed and loader-validated, so raw == the old
        # abi-only normalisation for every pre-existing record.
        for entry in $_TAGS
            set -l parts (string split '|' -- "$entry")
            if test "$parts[1]" = "$id"
                set tag_values (string split ',' -- "$parts[2]")
                break
            end
        end
        set -l groups_str (string join ',' $group_values)
        set -l edges_str (string join ',' $edge_values)
        set -l tags_str (string join ',' $tag_values)
        printf '%s|%s|%s|%s|%s\n' "$id" "$fields[2]" "$groups_str" "$edges_str" "$tags_str"
    end
end

function usage
    echo "Usage: build-all.fish [MAIN OPTIONS] [PACKAGE|RANGE...]"
    echo ""
    echo "Build and optionally install packages from this workspace."
    echo ""
    echo "Main options:"
    echo "  -g, --group GRP   Build package group(s) — A SELECTION IS REQUIRED:"
    echo "                    "(string join ', ' $_GROUP_NAMES)" (or package names)."
    echo "                    Multiple groups: repeat the flag or comma-separate,"
    echo "                    e.g. -g git -g core  /  -g git,core"
    echo "                    core = heavyweight, source-heavy, ABI-critical, and ROCm packages;"
    echo "                    auto-enables -i (installs immediately, rule 11)"
    echo "                    app = optional applications; on a TTY a build or -n run"
    echo "                    prompts to multi-select (all unchecked = build every app);"
    echo "                    non-TTY and -l build/list the whole group. App packages"
    echo "                    typically have no consumers, so an app selection usually"
    echo "                    stays leaf-only — but it expands like any other selection."
    echo "  -l, --list        List packages and their build order. Honours a"
    echo "                    selection: '-l -g git' prints the git selection — its"
    echo "                    members plus their consumers — and"
    echo "                    the indices it prints are exactly what a range selects."
    echo "                    With no selection it lists all packages."
    echo "  -n, --dry-run     Show build order without building. Honours a selection,"
    echo "                    and with none it shows the full order."
    echo "  -ia, --installall Install ALL built packages in the workspace (pacman -U);"
    echo "                    extra args are passed through to pacman, e.g.:"
    echo "                      build-all.fish -ia --overwrite '*'"
    echo "                    Group-install escape hatch only: it installs in ONE"
    echo "                    transaction, so it cannot satisfy rule 11"
    echo "                    (install-before-dependents-compile). Never use it in"
    echo "                    place of -i when packages in the set depend on each"
    echo "                    other — build with -i instead."
    echo "  -cc, --cleanup    Remove ALL built package archives (*.pkg.tar.zst)"
    echo "  -ccc, --nuclear   Remove pulled sources: src/pkg/build dirs, source git"
    echo "                    clones, and downloaded source tarballs (asks first)"
    echo "  --audit           Read-only report of legacy paths, package drift,"
    echo "                    stale runtime/error artifacts, cargo/rustc recipes"
    echo "                    with no rust-git edge, and installed PGO packages"
    echo "                    still carrying -fprofile-generate or"
    echo "                    -Cprofile-generate payloads"
    echo "  --topology        Print the resolved topology as machine-readable"
    echo "                    records, one per package:"
    echo "                      id|path|groups|edges|tags"
    echo "                    (comma-joined fields, empty = none; the data channel"
    echo "                    for tooling. The source of record is config/topology.conf)"
    echo "  -ln, --link-sources"
    echo "                    Dedup git source clones: symlink twins to one"
    echo "                    canonical mirror; repair origin/refspec; asks first"
    echo "  -h, --help        Show this help"
    echo ""
    echo "Build options (apply when a build is actually started):"
    echo "  -i, --install     Install each package IMMEDIATELY after it builds,"
    echo "                    in build order (pacman -U --noconfirm --ask 4 —"
    echo "                    unattended). Install failure aborts the run."
    echo "                    Lane installs run as 'sudo -n': the dispatcher keeps"
    echo "                    the cached credential warm (never prompts — an expired"
    echo "                    credential fails fast), and refuses to start when"
    echo "                    installs are impossible (instead of building for an"
    echo "                    hour first)."
    echo "                    This is the same behaviour the old -si/--sepinstall"
    echo "                    alias selected; that alias was removed 2026-09-17."
    echo "                    Before pacman runs, -i compares each archive with the"
    echo "                    installed database and skips a package whose exact"
    echo "                    version is already installed with an install date not"
    echo "                    older than the archive (a same-version rebuild still"
    echo "                    installs). Use -fi to bypass that check."
    echo "  -fi, --forceinstall"
    echo "                    Same as -i, but ALWAYS runs pacman -U — no same-version"
    echo "                    sanity check. Implies -i, so it works with or without it."
    echo "  --no-deps         Build only what you named (no consumer expansion)"
    echo "  -c, --clean       Clean build artifacts before building"
    echo "  -s, --skip        Skip fresh archives only when each VCS source ref matches"
    echo "                    its recorded revision; an unusable baseline rebuilds"
    echo "                    once if refs resolve. A ref upstream cannot answer even"
    echo "                    after transport retries parks that recipe (deferred:"
    echo "                    nothing is skipped or built, the rest of the run"
    echo "                    continues, exit stays non-zero)."
    echo "  --no-sync         Don't auto-update stable or opted-in recipe versions."
    echo "                    Stable recipes use pacman -Si; only a record tagged"
    echo "                    version-sync=nvchecker uses its .nvchecker.toml provider."
    echo "                    Moved sources are checked against published provider sums;"
    echo "                    missing GitHub digests are labelled fetch-only. Provider"
    echo "                    outages defer, while checksum mismatches stop the run and"
    echo "                    restore PKGBUILD. See docs/build-guide.md."
    echo "  --lanes N|auto     Run N makepkg lanes, or choose from CPU/RAM (default "(string join '' -- "$_DEFAULT_LANES")"). Interactive"
    echo "                    terminals get a compact dashboard with active log tails;"
    echo "                    pipes use plain output. Packages start as soon as deps are installed;"
    echo "                    core-group builds run solo with a memory-aware job limit."
    echo "  --jobs N|auto      Set jobs per normal lane, or derive it from CPU/RAM"
    echo "                    (default "(string join '' -- "$_DEFAULT_JOBS")")."
    echo "  --intensity LEVEL  Automatic resource profile: low, medium, high, xhigh,"
    echo "                    or max (default "(string join '' -- "$_DEFAULT_INTENSITY")")."
    echo "                    Explicit --lanes/--jobs override automatic profile values."
    echo "  --allow-broken-rustc"
    echo "                    Skip the rustc sanity probe (llvm-ABI-skew guard); only"
    echo "                    for runs that don't compile Rust"
    echo "  Environment: GSA_STATE_DIR, GSA_LANES, GSA_JOBS, GSA_INTENSITY,"
    echo "               GSA_CPU_THREADS, GSA_MEMORY_GIB, GSA_TARGET_CPU"
    echo "               override runtime state, parallelism, and optional CPU tuning."
    echo ""
    echo "Package references (a bare name is not a leaf build — it expands to"
    echo "its transitive consumers, the packages at ABI risk when it rebuilds;"
    echo "use --no-deps for one package):"
    echo "  mesa-git              Recipe ID"
    echo "  packages/git/mesa-git Recipe path"
    echo "  MESA-GIT              Case-variant ID (matched, and reported)"
    echo "  zen-browser           pacman package name, including a split output"
    echo "                        (built by recipe zen-browser-pgo) — also matched"
    echo "                        and reported. A typo is never auto-corrected;"
    echo "                        unknown names are reported with suggestions."
    echo ""
    echo "Range syntax (requires a -g group or package selection):"
    echo "  22..38            Build packages 22 through 38 of the SELECTION"
    echo "  22..              Build from package 22 to the end"
    echo "  ..15              Build from the start through package 15"
    echo "  Indices address the selection in build order — the list"
    echo "  'build-all.fish -l -g GROUP' prints, not the whole-set order that a"
    echo "  bare '-l' prints."
    echo ""
    echo "Examples:"
    echo "  build-all.fish -g git               Build top-level -git packages in dep order"
    echo "  build-all.fish -g git,core          Build git + core groups (deduped union)"
    echo "  build-all.fish -g core               Build core packages (auto-installs)"
    echo "  build-all.fish -g git -i            Same, installing each package as it finishes"
    echo "  build-all.fish -g git --lanes 2     Two parallel makepkg lanes over the git group"
    echo "  build-all.fish -g git --lanes 2 -i  Parallel lanes + immediate installs"
    echo "  build-all.fish -l -g git            List the git group with the indices that"
    echo "                                      its ranges address"
    echo "  build-all.fish --no-deps niri-spicy-git"
    echo "                                      Rebuild ONE package — build only what you named"
    echo "  build-all.fish glib2-git            Rebuild it + its 21 consumers (gtk4-git,"
    echo "                                      gimp-git, …) — use --no-deps to avoid this"
    echo "  build-all.fish -g git 22..38        Build packages 22-38 of the git group"
    echo "  build-all.fish -n -g core           Dry-run: show the core build order"
    echo "  build-all.fish -n                   Show full build order (dry run)"
    echo "  build-all.fish -ia --overwrite '*'  Same, passing pacman options through"
    echo "  build-all.fish -cc                  Delete all built package archives"
    echo "  build-all.fish -ccc                 Wipe pulled sources (src/pkg/build,"
    echo "                                      git clones, tarballs) — asks first"
    echo "  build-all.fish -ln                  Dedup git clones into shared mirrors"
    echo ""
    echo "Package groups:"
    for group_name in $_GROUP_NAMES
        set -l mangled (string replace - _ -- "$group_name")
        set -l var_name "_GROUP_$mangled"
        set -l members $$var_name
        set -l desc ""
        switch "$group_name"
            case git
                set desc "Top-level -git packages"
            case stable
                set desc "Stable/version-synchronized packages"
            case core
                set desc "Heavyweight, source-heavy, ABI-critical, and ROCm packages — auto-installs and runs core builds solo"
            case misc
                set desc "Auxiliary packages"
            case app
                set desc "Optional applications — typically no consumers, no auto -i"
        end
        printf '  %-12s %s (%s packages)\n' "$group_name" "$desc" (count $members)
    end
end

# ─── List packages ───────────────────────────────────────────────────────────
# Print a selection in build order. The first argument is the whole-set
# flag: 1 is the `-l` with no selection listing, which keeps the original
# heading and group footer byte-for-byte. Otherwise the selection is named, and
# the footer states what the printed indices are for — a range indexes THIS
# list, not the whole set. Remaining arguments are the packages, in order.
function list_packages -a all_flag
    set -l sorted_list $argv[2..-1]
    if test "$all_flag" = 1
        echo "All packages in build order:"
    else
        echo "Selected packages in build order ("(count $sorted_list)"):"
    end
    echo ""
    set -l i 1
    for pkg in $sorted_list
        printf "  %2d. %s\n" $i $pkg
        set i (math $i + 1)
    end
    echo ""
    if test "$all_flag" != 1
        echo "Ranges index this list: e.g. '22..38' selects entries 22-38 above."
        return 0
    end
    echo "Groups:"
    for group_name in $_GROUP_NAMES
        set -l mangled (string replace - _ -- "$group_name")
        set -l var_name "_GROUP_$mangled"
        set -l members $$var_name
        printf '  %-12s %s packages\n' "$group_name:" (count $members)
    end
end

# ─── Resolve one group name to its package list ──────────────────────────────
# Prints the package list; returns 1 for an unknown group. `-g core`
# additionally auto-enables -i in the caller (rule 11 — core rebuilds are
# only sound with immediate installs).
function resolve_group -a grp
    set -l name "$grp"
    # Every name matches exactly — a typo is never auto-corrected into a
    # different group (the third-party/3rdp aliases died with the group).
    if not contains "$name" $_GROUP_NAMES
        # This function's stdout is a data channel — the caller captures it
        # with a command substitution — so diagnostics must go to stderr or
        # they vanish silently (they did: `-g gti` exited 1 saying nothing).
        ui_error "unknown group '$grp'" >&2
        set -l near (printf '%s\n' $_GROUP_NAMES \
            | _nearest_lines "$grp" 2 | sort -n | head -1 | cut -d' ' -f2-)
        test -n "$near"; and echo "  Did you mean '$near'?" >&2
        echo "Available groups: "(string join ', ' $_GROUP_NAMES) >&2
        return 1
    end
    set -l mangled (string replace - _ -- "$name")
    set -l var_name "_GROUP_$mangled"
    set -l members $$var_name
    # printf with no arguments still runs the format once, printing a lone
    # newline — an empty group would then yield one phantom member that
    # topo_sort flags as a blocked package. Print only when there is
    # something to print.
    if test (count $members) -gt 0
        printf '%s\n' $members
    end
    return 0
end

# ─── app group multi-select prompt ──────────────────────────────────────────
# Filters the app group's members down to the user's checked subset — a layer
# in FRONT of the normal pipeline: whatever this prints becomes the group's
# contribution to build_list, and everything downstream (topo sort, ranges,
# lanes, install) is the code that already exists.
#
# Semantics: confirming with everything unchecked returns the WHOLE group
# (build all — the default state is all-unchecked); confirming with any entry
# checked returns only the checked subset; 'q' aborts with status 1.
#
# One line of input, whitespace-separated tokens:
#   N     toggle entry N          'a' check all
#   'c'   clear all               empty Enter confirm
#   'q'   abort the run
# Anything else re-renders with a notice. Display order is build order
# (topo_sort over just these members), so the menu reads like the build.
#
# stdout is the data channel (chosen IDs, one per line) — the menu, notices
# and the input hint all go to stderr so a command substitution cannot
# swallow them. The caller must only invoke this on a TTY (test -t 0);
# off-terminal runs never reach it, so there is no hang path in a pipe.
#
# Rows, not packages: members sharing one app-cluster=<name> tag render as a
# SINGLE toggle row (label '<name> [<member ids>]') at the cluster's first
# member's position in build order, and toggling that row checks or clears
# EVERY member at once (pkg_row maps each package to its row). A cluster
# member never renders its own row; untagged members are one row each.
function prompt_app_selection
    set -l items $argv
    test (count $items) -gt 0; or return 0
    set -l ordered (topo_sort (string join ' ' $items))
    set -l row_labels
    set -l row_members
    set -l row_cluster
    set -l pkg_row
    for pkg in $ordered
        set -l cluster (package_app_cluster $pkg)
        set -l row 0
        if test -n "$cluster"
            set -l r 1
            for seen in $row_cluster
                if test "$seen" = "$cluster"
                    set row $r
                    break
                end
                set r (math $r + 1)
            end
        end
        if test $row -eq 0
            set row (math (count $row_cluster) + 1)
            set -a row_cluster "$cluster"
            set -a row_members "$pkg"
            set -a row_labels "$pkg"
        else
            set row_members[$row] "$row_members[$row] $pkg"
        end
        set -a pkg_row $row
    end
    # Cluster rows relabel to '<name> [<member ids>]'; singletons keep the id.
    set -l row 1
    for cluster in $row_cluster
        if test -n "$cluster"
            set row_labels[$row] "$cluster ["$row_members[$row]"]"
        end
        set row (math $row + 1)
    end
    set -l checked
    while true
        printf '%s\n' "app group — choose what to build ("(count $ordered)" packages):" >&2
        printf '%s\n' "  default: nothing checked = build EVERY app package" >&2
        set -l i 1
        for label in $row_labels
            if contains -- "$i" $checked
                printf '  [x] %2d. %s\n' $i $label >&2
            else
                printf '  [ ] %2d. %s\n' $i $label >&2
            end
            set i (math $i + 1)
        end
        if test (count $checked) -gt 0
            printf '  %d checked — confirming now builds ONLY those\n' (count $checked) >&2
        end
        printf '%s\n' "numbers toggle (e.g. '1 3'), 'a' all, 'c' clear, Enter build, 'q' abort" >&2
        read -l input_line
        or begin
            ui_error "app selection aborted (input closed)" >&2
            return 1
        end
        set -l tokens (string match -ra '\S+' -- "$input_line")
        if test (count $tokens) -eq 0
            break # confirm
        end
        set -l invalid 0
        for token in $tokens
            switch $token
                case q quit
                    ui_error "app selection aborted" >&2
                    return 1
                case a all
                    set checked (seq (count $row_labels))
                case c clear
                    set checked
                case '*'
                    if string match -qr '^[0-9]+$' -- $token
                        and test $token -ge 1
                        and test $token -le (count $row_labels)
                        set -l at (contains -i -- "$token" $checked)
                        if test $status -eq 0
                            set -e checked[$at]
                        else
                            set -a checked $token
                        end
                    else
                        set invalid 1
                    end
            end
        end
        if test $invalid -eq 1
            printf '%s\n' " unrecognized token — use numbers, 'a', 'c' or 'q'" >&2
        end
        printf '\n' >&2
    end
    if test (count $checked) -eq 0
        printf '%s\n' $ordered # all-unchecked = build the whole group
        return 0
    end
    # Checked ROWS map back through pkg_row — a checked cluster row prints
    # every one of its member IDs here.
    set -l i 1
    for pkg in $ordered
        if contains -- "$pkg_row[$i]" $checked
            printf '%s\n' $pkg
        end
        set i (math $i + 1)
    end
    return 0
end

# ─── Main ────────────────────────────────────────────────────────────────────
function main
    set -l install_flag 0
    set -l force_install_flag 0
    set -l clean_flag 0
    set -l skip_flag 0
    set -l no_sync_flag 0
    set -l no_deps_flag 0
    set -l dry_run 0
    set -l list_flag 0
    set -l lane_count "$_DEFAULT_LANES"
    set -l jobs_override "$_DEFAULT_JOBS"
    set -l intensity_level "$_DEFAULT_INTENSITY"
    set -l allow_broken_rustc 0
    set -l groups
    set -l packages
    set -l ranges

    # Parse arguments
    set -l args $argv
    while test (count $args) -gt 0
        switch $args[1]
            case -i --install
                # Install each package IMMEDIATELY after it builds, in topo
                # order (pacman -U --noconfirm --ask 4). End-of-run collective
                # install was removed 2026-09-07: mid-run packages compiled
                # against the OLD installed deps (rust-git vs minimal
                # llvm-git incident) even with correct build order. The old
                # -si/--sepinstall alias for this behaviour was dropped
                # 2026-09-17: -i IS the separated install.
                set install_flag 1
            case -fi --forceinstall
                # -i WITHOUT the same-version sanity check: every selected
                # archive goes to pacman -U even when its exact version is
                # already installed (2026-09-25). Implies -i — "-fi" is
                # install + force, so it works with or without -i.
                set install_flag 1
                set force_install_flag 1
            case -c --clean
                set clean_flag 1
            case -s --skip
                set skip_flag 1
            case --no-sync
                set no_sync_flag 1
            case --lanes
                if test (count $args) -lt 2
                    ui_error "--lanes requires an argument"
                    return 1
                end
                if not parallelism_is_valid --lanes "$args[2]"
                    return 1
                end
                set lane_count $args[2]
                set -e args[2]
            case --jobs
                if test (count $args) -lt 2
                    ui_error "--jobs requires an argument"
                    return 1
                end
                if not parallelism_is_valid --jobs "$args[2]"
                    return 1
                end
                set jobs_override $args[2]
                set -e args[2]
            case --intensity
                if test (count $args) -lt 2
                    ui_error "--intensity requires an argument"
                    return 1
                end
                if not intensity_is_valid "$args[2]"
                    ui_error "--intensity expects low, medium, high, xhigh, or max; got '$args[2]'"
                    return 1
                end
                set intensity_level $args[2]
                set -e args[2]
            case --allow-broken-rustc
                # Escape hatch for check_rustc_sanity — for the rare case where
                # the skew is known/handled and rustc isn't needed by this run.
                set allow_broken_rustc 1
            case --no-deps
                # Build ONLY the named packages — no dependency-chain expansion.
                # Leaf rebuilds where the deps are known current (e.g. niri
                # without dragging in llvm/rust/mesa).
                set no_deps_flag 1
            case -n --dry-run
                set dry_run 1
            case -l --list
                # Deferred: the listing is printed from the resolved selection
                # (see the pipeline below), so `-l -g git` shows the indices a
                # range would select instead of ignoring the selection.
                set list_flag 1
            case -g --group
                if test (count $args) -lt 2
                    ui_error "--group requires an argument"
                    return 1
                end
                # Multiple groups: repeat the flag (-g git -g core) or
                # comma-separate (-g git,core). Deduped after parsing.
                for g in (string split ',' $args[2])
                    set -a groups $g
                end
                set -e args[2]
            case -h --help
                usage
                return 0
            case -ia --installall
                # Act immediately; everything after -ia is forwarded to pacman
                install_all $args[2..-1]
                return
            case -cc --cleanup
                # Act immediately; other options are ignored
                cleanup_pkgs
                return
            case -ccc --nuclear
                # Act immediately; other options are ignored
                nuclear_cleanup
                return
            case -ln --link-sources
                # Act immediately; other options are ignored. Git ops must run
                # as the user — root-owned .git files would break later builds.
                if test "$_ROOT_MODE" = "1"
                    ui_error "-ln does git operations — run it unprivileged (no sudo)."
                    return 1
                end
                if not require_command git
                    return 1
                end
                link_sources
                return
            case --audit
                audit_workspace
                return
            case --topology
                print_topology
                return
            case '-*'
                ui_error "unknown option: $args[1]"
                _suggest_option "$args[1]"
                usage
                return 1
            case '*..*'
                # Range syntax: 22..38, 22.., ..15
                set -a ranges $args[1]
            case '*'
                set -a packages $args[1]
        end
        set -e args[1]
    end

    # Determine packages to build — a selection is MANDATORY for a build. The
    # old default (no options = build everything) was removed 2026-09-07: an
    # unattended full rebuild is exactly how the rust/llvm ABI break happened.
    # The read-only actions (-l, -n) are exempt: they build nothing, so "no
    # selection" covers the whole set there (which is what --help advertises).
    set -l selection_given 0
    if test (count $packages) -gt 0 -o (count $groups) -gt 0
        set selection_given 1
    end
    # What was asked for, before consumer expansion. `$sorted` minus this set
    # is what the expansion added, reported for builds and dry runs: a bare name
    # can silently become a whole consumer-closure run.
    set -l requested
    set -l build_list
    if test (count $packages) -gt 0
        set -l canonical_packages
        for pkg in $packages
            set -l resolved (canonicalize_pkg_ref "$pkg")
            _ref_form_note "$pkg" "$resolved"
            set -a canonical_packages "$resolved"
        end
        set packages $canonical_packages
    end
    if test (count $groups) -gt 0
        # Resolve every selected group; dedupe overlapping selections.
        set -l groups_dedup (printf '%s\n' $groups | awk '!seen[$0]++')
        for g in $groups_dedup
            set -l gl (resolve_group $g)
            if test $status -ne 0
                return 1
            end
            # ── app prompt layer (decisions: TTY build/-n prompt, -l and
            # non-TTY take the whole group; filtered $gl then flows through
            # the unchanged pipeline below) ──────────────────────────────
            if test "$g" = app
                if test (count $gl) -eq 0
                    ui_warning "-g app: the app list is empty — populate config/topology.conf (an app entry in some record's groups field)"
                else if test "$list_flag" = 1
                    # -l lists the whole group, no prompt.
                else if test -t 0
                    set -l chosen (prompt_app_selection $gl)
                    if test $status -ne 0
                        return 1
                    end
                    set gl $chosen
                else
                    ui_info "-g app: no TTY — building the whole app group (prompt skipped)"
                end
            end
            if test "$g" = core; and test $install_flag -eq 0
                # Rule 11: core rebuilds are only sound with immediate
                # installs — later packages must compile against freshly
                # installed core dependencies, not old ABIs in the system.
                # A listing installs nothing, so it is not warned about.
                set install_flag 1
                if test "$list_flag" != 1
                    ui_warning "-g core: enabling -i (immediate per-package install) — core rebuilds without installs compile against old ABIs"
                end
            end
            set -a requested $gl
        end
    end
    # Positional packages may be combined with groups
    if test (count $packages) -gt 0
        # Validate specified packages
        for pkg in $packages
            set -l pkg_path (package_path "$pkg")
            if test -z "$pkg_path"; or not test -f "$pkg_path/PKGBUILD"
                _report_unknown_ref "$pkg"
                return 1
            end
        end
        set -a requested $packages
    end
    if test (count $requested) -gt 0
        set requested (printf '%s\n' $requested | awk '!seen[$0]++')
    end
    # Every selection form — positional refs, group members and app-prompt rows
    # alike — expands to ONE consumer closure over the whole request unless
    # --no-deps. The direction is consumers only (see expand_consumers): what
    # the request consumes is never pulled in.
    if test (count $groups) -gt 0 -o (count $packages) -gt 0
        if test $no_deps_flag -eq 1
            set build_list $requested
        else
            set -l expanded (expand_consumers $requested)
            if test $status -ne 0
                return 1
            end
            set build_list $expanded
        end
    else if test "$list_flag" = 1 -o "$dry_run" = 1
        # Read-only action with no selection: cover the whole set rather than
        # demanding one (see the header above).
        set -l all_members
        for group_name in $_GROUP_NAMES
            set -l mangled (string replace - _ -- "$group_name")
            set -l var_name "_GROUP_$mangled"
            set -a all_members $$var_name
        end
        set build_list (printf '%s\n' $all_members | awk '!seen[$0]++')
    else
        ui_error "no packages selected — pass -g GROUP and/or package names"
        echo "Groups: "(string join ', ' $_GROUP_NAMES)"   (see -h for examples)"
        echo "Read-only: -l lists packages, -n shows the build order without building."
        return 1
    end

    # Topological sort
    set -l sorted (topo_sort (string join ' ' $build_list))
    if test (count $_TOPO_BLOCKED) -gt 0
        ui_error "selection contains a dependency cycle or unresolved dependency"
        for pkg in $_TOPO_BLOCKED
            echo "  blocked: $pkg"
        end
        return 1
    end

    # Apply range filters (e.g. 22..38, 22.., ..15). Indices address the
    # SELECTION in build order — the list `-l -g GROUP` prints, which is
    # not the whole-set order a bare `-l` prints. Naming the bounds on a miss is
    # the difference between a typo and an unexplained empty build.
    if test (count $ranges) -gt 0
        set -l total (count $sorted)
        set -l indices
        for range in $ranges
            set -l parts (string split '..' $range)
            set -l start $parts[1]
            set -l end $parts[2]
            if test (count $parts) -ne 2; or not string match -qr '^[0-9]*$' -- "$start$end"; or test -z "$start$end"
                ui_error "invalid range '$range' — expected N..M, N.., or ..M (e.g. 22..38)"
                return 1
            end
            if test -z "$start"
                set start 1
            end
            if test -z "$end"
                set end $total
            end
            set start (math $start)
            set end (math $end)
            if test $start -gt $total; or test $end -lt 1
                ui_error "range $range is outside the $total-package selection (valid: 1..$total)"
                set -l list_args -l
                for g in $groups
                    set -a list_args -g $g
                end
                set -a list_args $packages
                echo "  Indices address the selection in build order; see them with:"
                echo "    build-all.fish "(string join ' ' -- $list_args)
                return 1
            end
            if test $start -gt $end
                ui_error "range $range is empty — the start is past the end"
                return 1
            end
            if test $start -lt 1
                ui_warning "range $range: start clamped to 1 (selection has $total packages)"
                set start 1
            end
            if test $end -gt $total
                ui_warning "range $range: end clamped to $total (the selection size)"
                set end $total
            end
            for i in (seq $start $end)
                set -a indices $i
            end
        end
        # Deduplicate indices and sort
        set -l unique_indices (printf '%s\n' $indices | sort -nu)
        set -l filtered
        for i in $unique_indices
            set -a filtered $sorted[$i]
        end
        set sorted $filtered
    end

    if test (count $sorted) -eq 0
        ui_error "selection resolved to no packages"
        return 1
    end

    # Generic coupled-batch gate (2026-09-25 llvm/rust incident, generalized:
    # the hard-coded llvm-git/rust-git pair was one instance of this rule, and
    # its Qt private-API siblings lived only in prose). Tags are topology data
    # in the record's tags field:
    #   abi=must    batch anchor or mandatory member
    #   abi=should  same-pass candidate (noted, never gated)
    # A batch ANCHOR is a selected abi=must package with no abi-tagged
    # dependency — the origin whose rebuild moves the batch ABI (llvm-git,
    # qt6-base-git, qt5-base-git). Its batch is the reverse closure the edge
    # file cannot express: every abi-tagged package that transitively depends
    # on it. On a REAL build (-n/-l are read-only and exempt), an installed
    # abi=must member omitted from the selection is refused — installing the
    # anchor's new ABI beside it would leave it stale the moment the archive
    # lands. An installed abi=should member is listed as a same-pass candidate.
    # A member that is not installed has nothing to protect and never gates.
    if test $dry_run -eq 0; and test $list_flag -eq 0
        set -l batch_missing
        set -l batch_candidates
        for anchor in $sorted
            test (package_abi_severity $anchor) = must; or continue
            has_abi_tagged_dependency $anchor; and continue
            for member in (abi_batch_dependents $anchor)
                contains $member $sorted; and continue
                pacman -Q $member >/dev/null 2>&1; or continue
                switch (package_abi_severity $member)
                    case must
                        set -a batch_missing (printf '%s %s' $anchor $member)
                    case should
                        set -a batch_candidates $member
                end
            end
        end
        if test (count $batch_missing) -gt 0
            set batch_missing (printf '%s\n' $batch_missing | sort -u)
            set -l first_pair (string split ' ' -- $batch_missing[1])
            ui_error "refusing to build $first_pair[1] without $first_pair[2] — the abi=must batch must rebuild in the same selection"
            echo "  $first_pair[1] is an abi=must batch anchor: rebuilding it moves the batch ABI,"
            echo "  and an omitted installed abi=must member is left stale against it."
            for entry in $batch_missing
                set -l pair (string split ' ' -- $entry)
                echo "  missing: $pair[2] — rebuild $pair[2] in the same run (add $pair[2] to the selection);"
            end
            echo "  if a toolchain is already broken, follow the check_rustc_sanity recovery text"
            echo "  (downgrade-rebuild the anchor's ABI packages to the snapshot the members"
            echo "  were built against)."
            return 1
        end
        if test (count $batch_candidates) -gt 0
            set batch_candidates (printf '%s\n' $batch_candidates | sort -u)
            ui_warning "same-pass candidates not in this selection: "(string join ', ' $batch_candidates)
            echo "  this run rebuilds an abi=must batch anchor; the packages above are installed"
            echo "  abi=should members whose ABI can be left stale against it."
        end
    end

    # List — read-only, and deliberately AFTER the range filter: the printed
    # indices are the ones a range selects, which is the whole point of `-l -g`.
    if test "$list_flag" = 1
        list_packages (test "$selection_given" = 0; and echo 1; or echo 0) $sorted
        return 0
    end

    # How much of this selection came from consumer expansion rather than the
    # request itself. Reported for builds and dry runs (the preview is where it
    # matters most); a listing already shows the whole set, so it stays quiet.
    set -l added_deps 0
    for pkg in $sorted
        contains "$pkg" $requested; or set added_deps (math $added_deps + 1)
    end
    if test $added_deps -gt 0; and test "$selection_given" = 1
        ui_info "consumer expansion added $added_deps of the "(count $sorted)" selected packages (--no-deps builds only what you named)"
    end

    # Dry run
    if test "$dry_run" = "1"
        echo "Build order (dry run):"
        echo ""
        set -l i 1
        for pkg in $sorted
            printf "  %2d. %s\n" $i $pkg
            set i (math $i + 1)
        end
        echo ""
        echo "Total: "(count $sorted)" packages"
        return 0
    end

    # Build
    ui_heading "Workspace Package Builder"
    echo "Packages: "(count $sorted)
    set -l install_summary no
    if test "$install_flag" = "1"
        set install_summary yes
        if test "$force_install_flag" = "1"
            set install_summary "yes (forced)"
        end
    end
    echo "Install:  $install_summary"
    echo "Clean:    "(test "$clean_flag" = "1"; and echo "yes"; or echo "no")
    echo "Lanes:    $lane_count"
    echo "Jobs:     $jobs_override (normal lanes; auto uses CPU/RAM)"
    echo "Intensity: $intensity_level"
    if test "$_ROOT_MODE" = "1"
        echo "User:     root (supervisor) — builds as $_BUILD_USER, installs as root"
    else
        echo "User:     $_BUILD_USER (installs via sudo, keepalive $_SUDO_KEEPALIVE_S s)"
    end
    echo "State:    $_STATE_DIR"
    echo ""

    # Register the run record's plan once for this run (the cluster's input
    # contract — see the run-record cluster below run_lanes). selection-source
    # renders as groups=… packages=… ranges=… with '-' for an absent part.
    set -l src_groups -
    set -l src_packages -
    set -l src_ranges -
    if test (count $groups) -gt 0
        set src_groups (string join ',' $groups)
    end
    if test (count $packages) -gt 0
        set src_packages (string join ',' $packages)
    end
    if test (count $ranges) -gt 0
        set src_ranges (string join ',' $ranges)
    end
    run_record_plan "$lane_count" "$jobs_override" "$intensity_level" \
        "$install_flag" "$force_install_flag" "$no_deps_flag" "$no_sync_flag" \
        "$allow_broken_rustc" \
        "groups=$src_groups packages=$src_packages ranges=$src_ranges" $sorted

    if test "$_ROOT_MODE" != "1"; and test "$install_flag" = "1"
        # The sudo hint is the ARGV-REPLAY mirror of continuation_args (see
        # the canonical flag → continuation-rule table with the cluster).
        set -l rerun_prefix (set_color yellow)
        set -l rerun_suffix (set_color normal)
        echo "$rerun_prefix$_UI_ICON_INFO unprivileged run: for -i runs that will take longer than ~15 min, prefer:$rerun_suffix"
        echo "  sudo fish $SCRIPT_DIR/build-all.fish "(continuation_args replay $argv)""
        echo "  (makepkg still builds as YOU — only the installs gain root; no password expiry)"(set_color normal)
        echo ""
    end

    if not ensure_state_dirs
        return 1
    end

    # Preflight: rustc sanity probe (llvm snapshot ABI-skew guard). Skipped on
    # dry runs — they build nothing. Bypass with --allow-broken-rustc.
    if test $allow_broken_rustc -eq 0
        if not check_rustc_sanity
            return 1
        end
    end
    if test "$_INTERRUPT_HANDLED" = "1"
        printf '\n'
        ui_warning "Build interrupted"
        dispatcher_log "Build interrupted (last signal: $_LAST_SIGNAL, before dispatch)"
        # An interrupted run prints the summary + machine block + continuation
        # and still exits 130 (2026-09-26 interrupt gap). Nothing dispatched
        # yet, so every row is never-started / interrupted-before-start.
        set -g _RL_INTERRUPTED 1
        run_record_finalize
        print_run_summary interrupted
        print_run_record interrupted 130
        return 130
    end

    # Parallel lane dispatcher (--lanes 1 = strict topo order, the old
    # sequential semantics). Installs happen inside lanes in readiness
    # order; a dependent never starts before all its deps are installed.
    run_lanes $lane_count $jobs_override $intensity_level $install_flag $clean_flag \
        $skip_flag $no_sync_flag $force_install_flag $sorted
    set -l run_rc $status

    # The run record is completed ONCE here — on every terminal path
    # (success, failure, sudo-preflight refusal, interrupt) — and the
    # renderings below consume it.
    run_record_finalize

    echo ""
    print_synced_notes

    set -l outcome failed
    if test "$_RL_INTERRUPTED" = "1"
        set outcome interrupted
    else if test $run_rc -eq 0
        set outcome success
    end
    print_run_summary "$outcome"
    # The machine block is printed only here — after the dashboard is
    # finished (finish_dashboard / abort_dashboard already ran).
    print_run_record "$outcome" $run_rc

    switch $outcome
        case success
            # With -i every package was installed right after its build, so there
            # is no collective end-install step anymore.
            return 0
        case interrupted
            return 130
    end
    return 1
end

if not load_project_config
    ui_error "project configuration is invalid under $CONFIG_DIR"
    exit 1
end

# ─── Signal handling ─────────────────────────────────────────────────────────
# dispatcher_log: one timestamped, [DEBUG-gsa-term]-tagged line per forensics
# event in $LOG_DIR/dispatcher.log. The 2026-09-23 incident left dispatcher
# and all six lanes dead at 19:34:01 with NO record of who sent what — this
# file is what names the signal on the next one.
function dispatcher_log -a message
    test -n "$message"; or return 0
    test -n "$LOG_DIR"; or return 0
    # Best-effort by contract (signal forensics must never fail the run):
    # shared helpers with stdout suppressed so a mid-dashboard call cannot
    # garble the renderer — their quarantine/repair notices ride stderr — and
    # a poisoned dispatcher.log is handled instead of silently losing this
    # line behind the 2>/dev/null append below.
    if not ensure_state_dirs >/dev/null
        return 0
    end
    if not ensure_log_writable "$LOG_DIR/dispatcher.log" >/dev/null
        return 0
    end
    printf '%s [DEBUG-gsa-term] %s\n' (date '+%Y-%m-%dT%H:%M:%S%z') "$message" \
        >>"$LOG_DIR/dispatcher.log" 2>/dev/null
end

# One-line pid/comm ancestry, newest first: who could have sent a signal.
function process_chain_snapshot
    set -l parts
    set -l pid $fish_pid
    for depth in (seq 6)
        set -l comm (ps -o comm= -p "$pid" 2>/dev/null | string trim)
        set -l ppid (ps -o ppid= -p "$pid" 2>/dev/null | string trim)
        test -n "$ppid"; or break
        test -n "$comm"; or set comm "?"
        set -a parts "$pid($comm)"
        if test -z "$ppid"; or test "$ppid" = 0
            break
        end
        set pid $ppid
        if test "$pid" = 1
            set -a parts "1(init)"
            break
        end
    end
    if test (count $parts) -eq 0
        echo "(unavailable)"
        return 0
    end
    string join ' <- ' -- $parts
end

# Shared handler body; the three binders below name their own signal + rc
# (fish offers no reliable "which signal" query inside a handler).
#
# Dispatcher mode (_LANE_JOB_ACTIVE unset/0): forensics FIRST (timestamped
# line naming the signal + ancestry), then _INTERRUPT_HANDLED is set exactly
# as the old combined handle_interrupt did — the run drains lanes through
# cleanup_active_lanes and exits 130 via the permanent "Build interrupted"
# event. HUP joins INT/TERM here: it previously had NO handler and orphaned
# live lanes outright.
#
# Lane mode (marker set by the --lane-job branch before any work): write an
# honest signal result (129 HUP / 130 INT / 143 TERM + pid/signal text in the
# package log) so the dispatcher records a real failure instead of rc=125
# "lane supervisor produced no valid result", then terminate immediately.
# fish 4.9.3 runs `exit` inside an event handler but discards the status
# (measured: always 0), so the child ERASES its own handler and re-raises the
# same signal: kernel default then yields 143/129 for TERM/HUP. INT is the
# documented exception — fish keeps an internal SIGINT path and a self-INT
# always exits 0 (measured even on a handler-less script), so a lane killed
# by INT exits 0 as a process; the honest 130 lives in the result file,
# which is the only channel the dispatcher reads.
function gsa_handle_signal -a sig rc binder
    if test "$_LANE_JOB_ACTIVE" = "1"
        set -g _LANE_SIGNAL_RC $rc
        if set -q _LANE_JOB_RESULT; and test -n "$_LANE_JOB_RESULT"
            set -l dur 0
            if set -q _LANE_JOB_START
                set -l now (date +%s)
                set dur (math "max(0, $now - $_LANE_JOB_START)")
            end
            if set -q _LANE_JOB_PKG; and test -n "$_LANE_JOB_PKG"
                write_lane_result "$_LANE_JOB_RESULT" "$_LANE_JOB_PKG" "$rc" "$dur"
                set -l pkg_log (package_log_file "$_LANE_JOB_PKG")
                # Best-effort: the honest signal line must not turn the
                # handler itself into a failure — skip only if the log is
                # unwritable even after quarantine/repair.
                if ensure_log_writable "$pkg_log"
                    printf '%s lane child received %s (rc=%s, pid=%s) — honest signal result recorded (outcome %s)\n' \
                        "$_UI_ICON_WARN" "$sig" "$rc" "$fish_pid" (lane_outcome_name "$rc") >>"$pkg_log"
                end
            else
                # Package identity never landed (argv never parsed): writing
                # a result under a fabricated identity (the old literal
                # `unknown` pkg) would put a non-package on the result wire
                # and make the reap's identity check a lie. Write NOTHING:
                # the dispatcher classifies a missing result as lane-lost and
                # names the lane — honest without inventing a pkg.
                echo "lane child received $sig before its identity was known — writing no result file" >&2
            end
        end
        # Die NOW: erase this handler, re-raise, then a best-effort exit
        # (see the fish-status caveat in the header — rc lands in the file).
        functions -e "$binder"
        command kill -s "$sig" $fish_pid 2>/dev/null
        exit $rc
    end
    # Dispatcher (or any non-lane mode): name the signal, then latch the flag.
    set -g _LAST_SIGNAL $sig
    dispatcher_log "signal: $sig received (pid=$fish_pid, prior_flag=$_INTERRUPT_HANDLED) chain="(process_chain_snapshot)
    set -g _INTERRUPT_HANDLED 1
end

function gsa_on_int --on-signal INT
    gsa_handle_signal INT $lane_outcome_int gsa_on_int
end

function gsa_on_term --on-signal TERM
    gsa_handle_signal TERM $lane_outcome_term gsa_on_term
end

function gsa_on_hup --on-signal HUP
    gsa_handle_signal HUP $lane_outcome_hup gsa_on_hup
end

if test (count $argv) -gt 0; and test "$argv[1]" = --lane-job
    # Marker globals BEFORE any work: gsa_handle_signal needs them to record
    # an honest outcome if this lane is signalled mid-build (2026-09-23: a
    # signal death used to leave no result at all → dispatcher rc=125).
    set -g _LANE_JOB_ACTIVE 1
    if test (count $argv) -ge 4
        set -g _LANE_JOB_PKG "$argv[2]"
        set -g _LANE_JOB_RESULT "$argv[3]"
        set -g _LANE_JOB_START (date +%s)
    end
    # The invocation shape lives in lane_argv_check (built by lane_argv on the
    # dispatcher side): an invalid invocation exits 2 — invocation error,
    # outside the lane_outcome_* vocabulary and never written to a result file.
    # UNQUOTED slice: fish keeps each element its own argument (no word
    # splitting), while "$argv[2..-1]" collapses a slice to ONE argument.
    lane_argv_check $argv[2..-1]
    if test $status -ne 0
        exit 2
    end
    lane_job $argv[2..-1]
    exit $status
end

# Hidden fixture seam (same precedent as --lane-job): run the production lock
# probe against an arbitrary path. rc 0 = absent/removed, 1 = busy/unremovable.
# No GSA_* test knob — the builder honours exactly the seven --help lists.
if test (count $argv) -gt 0; and test "$argv[1]" = --stale-lock-check
    if test (count $argv) -ne 2
        echo "Error: --stale-lock-check expects exactly one lock path" >&2
        exit 2
    end
    check_pacman_lock "$argv[2]"
    exit $status
end

# Hidden fixture seam (same precedent as --stale-lock-check): run the
# local-db integrity probe against an arbitrary directory. rc 0 = healthy or
# broken entries removed; 1 = broken entries remain (busy holder or
# permission denied). Never points at the host db unless a caller passes it.
if test (count $argv) -gt 1; and test "$argv[1]" = --local-db-check
    if test (count $argv) -ne 2
        echo "Error: --local-db-check expects exactly one local-db path" >&2
        exit 2
    end
    check_pacman_db_health "$argv[2]"
    exit $status
end

# Hidden fixture seam (same precedent as --stale-lock-check/--local-db-check):
# ask the install pipeline what it would DECIDE without executing anything —
# no pacman transaction, no sudo, no flock, no makepkg. The read-only
# `pacman -Qp/-Qi` probes still run through PATH (fixtures stub pacman), since
# the same-version skip decision fundamentally reads the installed database.
#   fish build-all.fish --install-decide <checked|force> [archive...]
# Output: the plan rows install_plan computed (its row grammar), one per line.
# rc 0 = executable plan (install/skip/noop rows), 1 = refusal rows, 2 = bad
# mode/usage. The plan is SILENT by design: this seam prints it verbatim and
# install_execute renders the same rows — one decision, two consumers.
if test (count $argv) -gt 0; and test "$argv[1]" = --install-decide
    if test (count $argv) -lt 2
        echo "Error: --install-decide expects <checked|force> and optional archives" >&2
        exit 2
    end
    if not contains -- "$argv[2]" checked force
        echo "Error: --install-decide mode must be checked or force" >&2
        exit 2
    end
    install_plan "$argv[2]" $argv[3..-1]
    exit $status
end

# Hidden fixture seam (same precedent as --stale-lock-check/--local-db-check):
# run ONE workspace-audit lint against the loaded workspace — no build, no
# network, no host state beyond the pacman.conf the caller names.
#   fish build-all.fish --audit-lint <provides|purged|ignorepkg> [pacman-conf]
# Output: one finding line per finding (prefix `provides: `/`purged: `/
# `ignorepkg: `) followed by `audit-lint <name>: clean`, `audit-lint <name>:
# N finding(s)` or `audit-lint ignorepkg: skipped`. rc 0 = the lint RAN — a
# finding never changes the exit status (report-only, the same contract
# --audit has) — 2 = usage. No GSA_* test knob.
if test (count $argv) -gt 0; and test "$argv[1]" = --audit-lint
    if test (count $argv) -lt 2; or test (count $argv) -gt 3
        echo "Error: --audit-lint expects <provides|purged|ignorepkg> and an optional pacman.conf path" >&2
        exit 2
    end
    switch $argv[2]
        case provides purged
            if test (count $argv) -ne 2
                echo "Error: --audit-lint $argv[2] takes no pacman.conf path" >&2
                exit 2
            end
        case ignorepkg
        case '*'
            echo "Error: --audit-lint expects provides, purged or ignorepkg" >&2
            exit 2
    end
    set -l lint_findings
    switch $argv[2]
        case provides
            set lint_findings (audit_lint_provides)
        case purged
            set lint_findings (audit_lint_purged)
        case ignorepkg
            set lint_findings (audit_lint_ignorepkg "$argv[3]")
    end
    for finding in $lint_findings
        echo "$finding"
    end
    if test "$argv[2]" = ignorepkg; and test (count $lint_findings) -eq 1; and string match -q 'ignorepkg: skipped*' -- $lint_findings[1]
        echo "audit-lint ignorepkg: skipped"
    else if test (count $lint_findings) -eq 0
        echo "audit-lint $argv[2]: clean"
    else
        echo "audit-lint $argv[2]: "(count $lint_findings)" finding(s)"
    end
    exit 0
end

main $argv
