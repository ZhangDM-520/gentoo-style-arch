#!/usr/bin/env fish
# build-all.fish — Workspace package builder with dependency ordering
# Builds and optionally installs Arch Linux packages from PKGBUILDs in this workspace.

set -g SCRIPT_DIR (realpath (status dirname))
set -g CONFIG_DIR "$SCRIPT_DIR/config"
# One topology file: per-package records (id|path|groups|edges[|tags]) replace
# the former packages.map + groups/*.list + dependencies.conf trio (2026-09-26).
set -g TOPOLOGY_FILE "$CONFIG_DIR/topology.conf"
set -g DEFAULT_CONFIG_FILE "$CONFIG_DIR/build-defaults.conf"
# The ABI-drift guard's documented exception registry (Tier-2 exclusions,
# format documented in the file's header). Wired like the other config: a
# present file is strictly validated on every invocation (read_abi_exclusions);
# an absent one is an empty registry, never a silent wildcard.
set -g ABI_EXCLUSIONS_FILE "$CONFIG_DIR/abi-exclusions.conf"
set -g _STATE_DIR "$SCRIPT_DIR/.state"
if set -q GSA_STATE_DIR; and test -n "$GSA_STATE_DIR"
    # Control characters are rejected HERE (the env knob's first read): the
    # lane spawn payload is newline-framed (lane_argv), so a state dir with a
    # newline or other control char would corrupt the 8-arg boundary and the
    # run-scoped result paths built from it (R-F30). lane_argv_check refuses
    # the same class at the receiving end as the backstop.
    if string match -qr '[\x00-\x1f\x7f]' -- "$GSA_STATE_DIR"
        echo "Error: GSA_STATE_DIR must not contain control characters" >&2
        exit 1
    end
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
# failure (which collapses to lane_outcome_failed like every other non-zero —
# the run-record ROW reason names it `mutex-timeout`).
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
# lane_outcome_name RC → the run-record reason token for RC (ok, failed,
# defer, lost, signal-hup, signal-int, signal-term). The signal outcomes spell
# their DISPLAY form `signal-*` — what the row grammar and the classifier
# teach — while the lane_outcome_* constants keep the short names. Any number
# outside the vocabulary decodes as `failed` — the failure branch is the
# conservative default, never a silent success.
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
# Second-signal escalation (R-F15): the first signal latches the interrupt and
# drains lanes through the normal TERM→grace→KILL teardown; a SECOND signal
# must mean "now" — gsa_handle_signal then SIGKILL-sweeps the active lanes
# immediately, no grace.
set -g _SIGNAL_ESCALATED 0
# Foreground-child tracking (R-F15): fish defers --on-signal handlers until an
# in-flight FOREGROUND command exits (measured on fish 4.9.3: SIGINT at t=0.5 s
# to `sleep 4` ran the handler at t=4.0 s), but runs them promptly during a
# `wait` on a backgrounded job. The dispatcher therefore runs its waits as
# tracked background children and records the pid here; the handler signals it
# too ("signal both") so the loop unblocks at the signal, not at the child's
# natural exit.
set -g _FG_CHILD_PID ""
# Run identity (R-F9): one id per run, carried in every result filename
# (.lane.<run-id>.<lane>.result) so another run's or an orphan's write can
# never land in THIS run's slot. The internal _GSA_RUN_ID env seam pins it for
# fixtures (same class as _LANE_STOP_GRACE_S: not a public GSA_* input).
set -g _RUN_ID ""
set -g _RUN_LOCK_HOLDER ""
# The grace defaults to 30 s but an exported value overrides it: an
# underscore-prefixed INTERNAL seam (tests/dashboard.sh shortens it so the
# post-grace KILL path can be proven in seconds). The GSA_* inputs listed in
# --help are unchanged. Non-numeric junk falls back to 30.
if not set -q _LANE_STOP_GRACE_S; or not string match -qr '^[0-9]+$' -- $_LANE_STOP_GRACE_S
    set -g _LANE_STOP_GRACE_S 30
end

# ─── Project configuration ───────────────────────────────────────────────────
# The group roster is stated ONCE, here. Group membership lives in each
# topology record's groups field; only these six names are readable anywhere
# (loader validation, resolve_group, usage, diagnostics all derive from this
# list). Group variables are _GROUP_<name with '-' as '_'>.
# 2026-09-27: third-party retired — its members moved to app; `-g third-party`
# now fails through the unknown-group path (its members' recipes were never
# reachable through the group name again).
# 2026-10-04: build-tools added — a dispatch-first SCHEDULING class with
# exactly one behavioural effect (the lane dispatcher picks its ready members
# before all other ready packages, never over build-order edges), dual with
# core: every member also carries core, so its core SOLO builds hold through
# that membership — but the -i auto-enable keys on the literal `-g core`
# selection (main's group loop), so a `-g build-tools` run never installs on
# its own.
set -g _GROUP_NAMES git stable core misc app build-tools
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
set -g _GROUP_build_tools
set -g _DEFAULT_LANES auto
set -g _DEFAULT_JOBS auto
set -g _DEFAULT_INTENSITY xhigh
set -g _MEMORY_PER_JOB_GIB 3
set -g _CORE_MEMORY_PER_JOB_GIB 4
set -g _RESERVED_MEMORY_GIB 2

function package_path -a package_id
    # O(1) keyed lookup (_TPATH_ published by read_topology_config); the old
    # linear _PACKAGE_MAP scan cost 650 string splits per call — it was the
    # dispatcher profile's largest self-time item at scale.
    set -l path_var _TPATH_(_topo_key "$package_id")
    if set -q $path_var
        echo "$SCRIPT_DIR/$$path_var"
        return 0
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

# build-defaults.conf: one key=value per line, keys named in the switch
# below. Every failure here names its OFFENDER (line number + text, or the
# unreadable file), like read_topology_config does: the caller can only say
# "invalid build defaults: <file>", so a bare return 1 leaves the user
# bisecting by hand (the loader's 2026-09-20 rule).
function read_config_defaults
    test -f "$DEFAULT_CONFIG_FILE"; or return 1
    set -l raw_lines (cat -- "$DEFAULT_CONFIG_FILE" 2>/dev/null)
    if test $status -ne 0
        # A failed read must NOT parse as empty: the built-in defaults would
        # silently replace the user's file and the next disagreement gets
        # blamed on a key they never broke.
        ui_error "build defaults unreadable: $DEFAULT_CONFIG_FILE"
        return 1
    end
    set -l line_no 0
    for raw_line in $raw_lines
        set line_no (math $line_no + 1)
        set -l line (string trim -- "$raw_line")
        test -n "$line"; or continue
        string match -q '#*' -- "$line"; and continue
        set -l fields (string split -m 1 '=' -- "$line")
        if test (count $fields) -ne 2
            ui_error "invalid build defaults line $line_no (expected 'key=value'): $line"
            return 1
        end
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
                ui_error "unknown key in build defaults line $line_no: $line"
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

# _topo_key ID... → each ID in variable-name form, for the O(1) keyed indexes
# the loader publishes (_TID_/_TDEP_/_TCONS_/…). fish has no associative
# arrays and `contains` over the ~650-entry id list costs ~105µs per lookup,
# which the old O(E×P) scans paid per edge. The map is the homomorphism
# a→a (alnum), _→_5f, .→_2e, -→_2d, +→_2b: a prefix-free codebook over the
# id charset ([A-Za-z0-9._+-]), so distinct ids yield distinct keys — do not
# replace it with `string escape --style=var`: its escaping is context-
# dependent (.0a → _2E_30_a) and its injectivity cannot be argued. Takes
# VARARGS (one cmdsub per LIST of ids, not per id — a single call already
# pays the ~20µs substitution cost) and prints one key per id, in order.
function _topo_key
    # No stdin fallback: `string replace` with no strings would READ STDIN.
    test (count $argv) -gt 0; or return 0
    string replace -a -- _ _5f $argv | string replace -a -- . _2e \
        | string replace -a -- - _2d | string replace -a -- + _2b
end

# Read config/topology.conf — the ONE topology source. One record per package:
#   id|path|groups|edges[|tags]
# (a lone id|path|groups| is a deliberate no-edge record; records ALWAYS exist
# for every package). Every validation path below names its offending record
# or field: the caller can only say "project configuration is invalid", so a
# bare return 1 leaves the user bisecting by hand (2026-09-20 rule).
function read_topology_config
    # Re-reads (unverifiable_defer_plan) start from a clean index: a keyed var
    # left by a previous parse would answer lookups for an id this parse never
    # saw. The keyed vars are erasable by NAME PATTERN from `set -n` — do not
    # track them in a growing list: fish's `set -a` copies the whole list per
    # append, so bookkeeping 9k names that way cost ~2s on its own. The
    # pattern MUST match each name in full and use a non-capturing group:
    # `string match -r` prints only the matched portion (a prefix pattern
    # erases nothing) and additionally prints capture groups as names (2026-10-05).
    set -l stale_keys (set -n | string match -r '^_(?:TID|TPATH|TDEPKEYS|TDEP|TCONSKEYS|TCONS|TTAGS)_.*$')
    if test (count $stale_keys) -gt 0
        set -e $stale_keys
    end
    set -g _PACKAGE_MAP
    set -g _PACKAGE_IDS
    set -g _DEPS
    set -g _CONSUMER_INDEX
    set -g _TAGS
    for group_name in $_GROUP_NAMES
        assign_group "$group_name"
    end
    # Edge targets may name records further down the file, so edge validation
    # is deferred until every id is known; the deferred pass reads each
    # record's dep names (_TDEP_) and their keys (_TDEPKEYS_) — published in
    # the record loop below, index-aligned — straight off the keyed index.
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
        set -l id_key (_topo_key "$id")
        if set -q _TID_$id_key
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
        # One key derivation for the whole dep list (see _topo_key), aligned
        # with $record_edges by position.
        set -l record_dep_keys (_topo_key $record_edges)
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
        # O(1) keyed index (see _topo_key), published alongside the legacy
        # row-shaped lists above — which stay byte-identical because other
        # seams read them. _TDEPKEYS_ mirrors _TDEP_ with keys so later graph
        # walks never derive a key per edge again.
        set -g _TID_$id_key "$id"
        set -g _TPATH_$id_key "$relative_path"
        set -g _TDEP_$id_key $record_edges
        set -g _TDEPKEYS_$id_key $record_dep_keys
        set -g _TTAGS_$id_key (string join ',' $record_tags)
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
    # _pkgname_index shape) and its O(1) keyed twin _TCONS_/_TCONSKEYS_:
    # selection expansion walks CONSUMERS — the set at ABI risk when a package
    # rebuilds — and that walk needs "who consumes this" on every node, which
    # scanning _DEPS forward cannot answer. The record loop already published
    # each record's dep names (_TDEP_) and their keys (_TDEPKEYS_),
    # index-aligned and empty-free, so this pass derefs those instead of
    # round-tripping string rows through join/split (the old shape also
    # shifted a shrinking key list per record — O(P²) list copies).
    for pkg in $_PACKAGE_IDS
        set -l pkg_key (_topo_key "$pkg")
        set -l deps_var _TDEP_$pkg_key
        set -l deps $$deps_var
        set -l dep_keys_var _TDEPKEYS_$pkg_key
        set -l dep_keys $$dep_keys_var
        set -l record_edges
        # Collected per record and appended in ONE call: fish's `set -a`
        # copies the whole list per append, so per-edge appends to the global
        # reverse index were O(E²) copies.
        set -l cons_pairs
        for dep in $deps
            set -l dep_key "$dep_keys[1]"
            set dep_keys $dep_keys[2..-1]
            test -n "$dep"; or continue
            if not set -q _TID_$dep_key
                ui_error "topology record for $pkg names an unknown dependency: $dep"
                return 1
            end
            set -a record_edges "$dep"
            set -a cons_pairs "$dep|$pkg"
            set -ga _TCONS_$dep_key "$pkg"
            set -ga _TCONSKEYS_$dep_key "$pkg_key"
        end
        set -a _CONSUMER_INDEX $cons_pairs
        set -a _DEPS (printf '%s:%s' "$pkg" (string join ',' $record_edges))
    end
    return 0
end

# Read config/abi-exclusions.conf — the ABI-guard's documented exception
# registry. One entry per line: id|reason|review-by (the file's header is the
# normative format doc). `#` lines and blanks are ignored. Strict like
# topology: a malformed entry fails every command with the offending line
# named — an exception registry that silently misparses is exactly the silent
# gap the guard exists to prevent. An ABSENT file is a valid empty registry
# (a scratch workspace may simply carry no exceptions).
function read_abi_exclusions
    set -g _ABI_EXCLUSIONS
    set -g _ABI_EXCLUSION_IDS
    test -f "$ABI_EXCLUSIONS_FILE"; or return 0
    set -l line_no 0
    for raw_line in (cat "$ABI_EXCLUSIONS_FILE")
        set line_no (math $line_no + 1)
        set -l line (string trim -- "$raw_line")
        test -n "$line"; or continue
        string match -q '#*' -- "$line"; and continue
        set -l fields (string split '|' -- "$line")
        if test (count $fields) -ne 3
            ui_error "invalid abi-exclusions entry (expected 'id|reason|review-by'): $ABI_EXCLUSIONS_FILE line $line_no"
            return 1
        end
        set -l id (string trim -- "$fields[1]")
        set -l reason (string trim -- "$fields[2]")
        set -l review_by (string trim -- "$fields[3]")
        if not string match -qr '^[A-Za-z0-9._+-]+$' -- "$id"
            ui_error "invalid abi-exclusions id '$id' (allowed: A-Za-z0-9._+-): $ABI_EXCLUSIONS_FILE line $line_no"
            return 1
        end
        if test -z "$reason"
            ui_error "abi-exclusions entry $id has no reason: $ABI_EXCLUSIONS_FILE line $line_no"
            return 1
        end
        if not string match -qr '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' -- "$review_by"
            ui_error "abi-exclusions entry $id has no ISO review-by date: $ABI_EXCLUSIONS_FILE line $line_no"
            return 1
        end
        if contains -- "$id" $_ABI_EXCLUSION_IDS
            ui_error "duplicate abi-exclusions id: $id ($ABI_EXCLUSIONS_FILE line $line_no)"
            return 1
        end
        set -a _ABI_EXCLUSION_IDS "$id"
        set -a _ABI_EXCLUSIONS "$id|$review_by|$reason"
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
    # The ABI-guard's exception registry is config too: it loads here so the
    # same strict-loader contract covers it (read_abi_exclusions names every
    # offender).
    if not read_abi_exclusions
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
# Order-identical O(V+E) Kahn since 2026-10-04: the previous nested-list
# scanner re-split every record inside O(V×E) loops (millions of string splits
# per call over 653 records / 3373 edges — the whole multi-minute `--list`
# latency, paid TWICE per invocation). Lookups here are keyed variables built
# from _topo_key (function-scoped, so calls cannot see each other's maps):
# `contains --index` marshals the whole $pkgs list per call (~105µs over 650
# names), which the edge pass paid per dep. The reverse adjacency is
# precomputed in one pass. The ORDER printed is load-bearing and unchanged:
# zero-in-degree members queued in $pkgs order, FIFO processing, decrements in
# $_DEPS record order against the FIRST $pkgs occurrence of each consumer,
# leftovers appended in $pkgs order.
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

    # One key derivation for the whole list (_topo_key is varargs), then the
    # $pkgs index of each name's FIRST occurrence — the "first matching entry
    # wins" slot the old scans found by brute force. The in-degree and reverse
    # maps live on those slots; a name occurring twice still gets its own
    # queue entry and its own place in $sorted, exactly like the old
    # per-occurrence bookkeeping. The slots themselves are read back from the
    # _TSI_ map on demand, so no parallel index array is kept.
    set -l pkg_keys (_topo_key $pkgs)
    set -l idxs (seq (count $pkgs))
    for j in $idxs
        set -l slot_var _TSI_$pkg_keys[$j]
        if not set -q $slot_var
            set -f $slot_var $j
        end
    end

    # in_degree[i] = count of $pkgs[i]'s deps that are in the build list,
    # addressed at first-occurrence slots (decrements always landed on the
    # first matching entry too). rev[i] = consumer indices that $pkgs[i]
    # unblocks, in $_DEPS record order — the order the old scan decremented in.
    # Both maps are keyed lists, not indexed arrays: _TDI_<slot> holds one
    # `_pending` marker per in-list dep TOKEN (a repeated token adds two
    # markers, exactly the old `math` count), so a decrement is `set -e deg[1]`
    # and zero in-degree is an empty list — no `math`, no whole-array copy.
    # _TREV_<slot> is the consumer slots in record order. Both are
    # function-scoped, so they die with the call and need no stale sweep.
    # (Array writes were the hot cost: `set arr[i]` copies the whole array and
    # `math` is a ~16µs command substitution per edge.)

    # ONE pass over $_DEPS ("id:dep1,dep2") builds both maps. Same-input
    # fidelity with the old loops: a dep token repeated inside one record adds
    # +2 to the in-degree count (the old init loop counted every token) but
    # only ONE reverse edge (the old edge scan matched each record once per
    # pop, breaking at the first equal dep).
    for entry in $_DEPS
        set -l parts (string split ':' $entry -m 2)
        if test (count $parts) -ge 2 -a -n "$parts[2]"
            set -l owner_key (_topo_key "$parts[1]")
            set -l ci_var _TSI_$owner_key
            if set -q $ci_var
                set -l ci $$ci_var
                # Dep keys ride along from read_topology_config (_TDEPKEYS_),
                # index-aligned with the row's dep tokens (the loader drops
                # empty tokens before publishing both), so this pass never
                # derives a key per edge — and the key IS the loop token: the
                # map is injective, so the old name-equality dedup is exactly
                # key-equality here.
                set -l dep_keys_var _TDEPKEYS_$owner_key
                set -l dep_keys $$dep_keys_var
                set -l rev_seen
                for dep_key in $dep_keys
                    test -n "$dep_key"; or continue
                    set -l di_var _TSI_$dep_key
                    set -q $di_var; or continue
                    set -l di $$di_var
                    set -f -a _TDI_$ci _pending
                    contains -- "$dep_key" $rev_seen; and continue
                    set -a rev_seen "$dep_key"
                    set -f -a _TREV_$di $ci
                end
            end
        end
    end

    # Kahn's algorithm
    set -l queue
    set -l queue_keys
    set -l sorted

    # Zero-in-degree members queue in $pkgs order — one entry per OCCURRENCE,
    # as the old init loop appended them. The first-occurrence slot comes
    # straight from the _TSI_ map built above. Each queue entry carries its
    # key, so the pop loop never derives one.
    for j in $idxs
        set -l slot_var _TSI_$pkg_keys[$j]
        set -l f $$slot_var
        set -l deg_var _TDI_$f
        set -l deg $$deg_var
        if not set -q deg[1]
            set -a queue $pkgs[$j]
            set -a queue_keys $pkg_keys[$j]
        end
    end

    # Process queue. The queue is consumed through a moving head instead of
    # `set -e queue[1]`: deleting the head reindexes the whole list per pop.
    set -l qhead 1
    while test $qhead -le (count $queue)
        set -l pkg $queue[$qhead]
        set -l pkg_key $queue_keys[$qhead]
        set qhead (math $qhead + 1)
        set -a sorted $pkg
        set -f _TSORTED_$pkg_key 1

        # Every consumer this package unblocks, in record order; the reverse
        # list holds first-occurrence indices, so decrementing the in-degree
        # markers there is exactly the old "first entry named child" scan.
        # The guard on the decrement is load-bearing: a name occurring twice
        # can be queued (and popped) twice, traversing _TREV_ twice, and the
        # old `math` count then went negative and never re-readied the slot —
        # so a decrement with no marker left is skipped and queues nothing.
        set -l di_var _TSI_$pkg_key
        if set -q $di_var
            set -l di $$di_var
            set -l rev_var _TREV_$di
            for ci in $$rev_var
                set -l deg_var _TDI_$ci
                set -l deg $$deg_var
                if set -q deg[1]
                    set -e deg[1]
                    set -f $deg_var $deg
                    if not set -q deg[1]
                        set -a queue $pkgs[$ci]
                        set -a queue_keys $pkg_keys[$ci]
                    end
                end
            end
        end
    end

    # Append any remaining (cycles or missing deps) at the end. Membership is
    # the function-scoped _TSORTED_ marker set at pop time — `contains` over
    # $sorted re-marshalled the growing list per remaining name.
    for j in $idxs
        set -l pkg_key $pkg_keys[$j]
        if not set -q _TSORTED_$pkg_key
            # Mark as well: the old `contains` test saw leftovers appended by
            # this very loop, so a repeated name is appended (and reported
            # blocked) exactly once.
            set -f _TSORTED_$pkg_key 1
            set -a _TOPO_BLOCKED $pkgs[$j]
            set -a sorted $pkgs[$j]
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
    # Keys ride beside the queue (_topo_key is varargs — one call for the
    # whole seed list, exactly one key per name, order preserved), so no pop
    # derives one.
    set -l queue_keys (_topo_key $argv)

    # The queue is consumed through a moving head (see topo_sort) and the
    # seen set is function-scoped keyed membership: the old inner loop
    # re-scanned every _CONSUMER_INDEX row per dequeued node (O(C×E) string
    # splits) and re-walked $result for the dedupe.
    set -l qhead 1
    while test $qhead -le (count $queue)
        set -l pkg $queue[$qhead]
        set -l key $queue_keys[$qhead]
        set qhead (math $qhead + 1)

        # Skip if already in result
        set -l seen_var _ECS_$key
        if set -q $seen_var
            continue
        end
        set -f $seen_var 1

        set -a result $pkg

        # Every record that lists $pkg among its edges consumes it: pull the
        # consumer side of the reverse adjacency (built once by
        # read_topology_config, in _CONSUMER_INDEX scan order — the order the
        # old scan pushed consumers in).
        set -l cons_var _TCONS_$key
        if set -q $cons_var
            set -l consumers $$cons_var
            set -l cons_keys_var _TCONSKEYS_$key
            set -l consumer_keys $$cons_keys_var
            for consumer in $consumers
                set -l consumer_key "$consumer_keys[1]"
                set consumer_keys $consumer_keys[2..-1]
                if set -q _TID_$consumer_key
                    set -a queue $consumer
                    set -a queue_keys $consumer_key
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
    set -l exp_status $status
    if test $exp_status -ne 0
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

# report_pkgbuild_eval_failures PATH... — the -ccc/-ln surface for recipes the
# evaluator could not read: named, and rc 1 so "nothing to clean" can never
# claim success over a recipe whose sources were never scanned. Empty = rc 0.
function report_pkgbuild_eval_failures
    if test (count $argv) -eq 0
        return 0
    end
    ui_error (count $argv)" recipe(s) could not be evaluated; their sources were NOT scanned:"
    printf '  %s\n' $argv
    return 1
end

# ─── Archive currency: which archive is current? ─────────────────────────────
# One oracle for the whole seam: an archive is CURRENT only when its filename
# maps to an expected output at the EVALUATED pkgver-pkgrel, and EVERY
# expected output has one. "Has an archive" means "has the COMPLETE
# current-version set", never a subset — a split set cut apart by a
# mid-packaging SIGKILL must neither skip nor install.

# expected_output_names PKG_PATH → the outputs a complete build must produce.
# The committed .SRCINFO is the recipe's published claim (already expanded;
# tests/srcinfo-freshness.sh keeps it in step); synthetic workspaces ship no
# .SRCINFO and fall back to the evaluated pkgname array, the same claim one
# level down. Neither answer yields nothing — an expected set that cannot be
# established never blesses an archive set.
function expected_output_names -a pkg_path
    set -l names
    if test -f "$pkg_path/.SRCINFO"
        set names (srcinfo_output_names "$pkg_path/.SRCINFO")
    end
    if test (count $names) -eq 0
        # An evaluation failure lands here as "no outputs", which is
        # fail-closed for every caller (nothing is blessed as current), so the
        # fallback is honest even though the reason is not distinguishable.
        set names (pkgbuild_array_checked "$pkg_path" pkgname)
    end
    if test (count $names) -gt 0
        printf '%s\n' $names
    end
    return 0
end

# archive_matches_output ARCHIVE NAME PV PR → 0 when the filename is
# NAME-PV-PR-<arch>.pkg.tar.zst. Literal string surgery only — pkgver is
# recipe data and may carry glob/regex metacharacters, so the prefix is never
# a pattern; the arch token is free-form and must carry no dash.
function archive_matches_output -a archive name pv pr
    set -l base (basename -- "$archive")
    set -l stem "$name-$pv-$pr-"
    set -l stem_len (string length -- "$stem")
    if test (string length -- "$base") -le $stem_len
        return 1
    end
    if test (string sub -s 1 -l $stem_len -- "$base") != "$stem"
        return 1
    end
    string match -qr -- '^[^-]+\.pkg\.tar\.zst$' (string sub -s (math "$stem_len + 1") -- "$base")
end

# current_archives PKG_PATH → the covered archives (every archive that maps to
# an expected output at the evaluated pkgver-pkgrel, sorted) and the state of
# the SET:
#   0 complete  every expected output has a current-version archive
#   1 none      nothing is current (fresh workspace, or only stale versions)
#   2 partial   some outputs covered — the one state that must never bless a
#               skip or an install; _CURRENT_ARCHIVES_MISSING names the rest.
#   3 unknown   discovery could not be established (pkgver/pkgrel evaluation
#               failed or yielded nothing usable) — distinct from `none` so a
#               listing caller can refuse a damaged recipe instead of
#               confusing it with a not-yet-built one (R-F25).
# One archive maps to exactly one output name (the NAME-PV-PR- prefix is
# unique per output); a same-version ARCH-flavour leftover therefore rides
# along with the build's own archive instead of silently displacing it.
function current_archives -a pkg_path
    set -g _CURRENT_ARCHIVES_MISSING
    set -l metadata (pkgbuild_version "$pkg_path")
    if test $status -ne 0; or test (count $metadata) -ne 2
        ui_error "$(basename "$pkg_path"): could not evaluate pkgver/pkgrel for archive discovery" >&2
        return 3
    end
    set -l pv (string replace -r '^pkgver=' '' -- "$metadata[1]")
    set -l pr (string replace -r '^pkgrel=' '' -- "$metadata[2]")
    # Unknown version metadata cannot prove an archive current; never broaden
    # discovery to every archive when the version-specific pattern is unknown.
    if test -z "$pv" -o -z "$pr"
        return 3
    end
    set -l expected (expected_output_names "$pkg_path")
    if test (count $expected) -eq 0
        return 3
    end
    # find -printf %T@: nanosecond mtimes, newest first (fish globs would
    # FATAL on "no matches"; find -name returns 0 with none).
    set -l rows (find "$pkg_path" -maxdepth 1 -type f -name '*.pkg.tar.zst' \
        -printf '%T@\t%p\n' 2>/dev/null | sort -rn)
    set -l chosen
    for name in $expected
        set -l covered 0
        for row in $rows
            set -l fields (string split \t -- "$row")
            if test (count $fields) -ne 2
                continue
            end
            if archive_matches_output "$fields[2]" "$name" "$pv" "$pr"
                set -a chosen "$fields[2]"
                set covered 1
            end
        end
        if test $covered -eq 0
            set -a _CURRENT_ARCHIVES_MISSING "$name"
        end
    end
    if test (count $chosen) -gt 0
        printf '%s\n' $chosen | sort
    end
    if test (count $_CURRENT_ARCHIVES_MISSING) -eq 0
        return 0
    end
    if test (count $chosen) -eq 0
        return 1
    end
    return 2
end

# archive_payload_ok ARCHIVE → 0 only when the package payload reads end to
# end. pacman -Qp decompresses the whole zstd stream before answering (a write
# killed at ANY offset fails it — measured against cuts at the last 100
# bytes), which is exactly the mid-packaging SIGKILL shape that used to
# re-skip forever. Read-only and lock-free like install_skip_reason's queries.
# Doubt FAILS CLOSED here, the opposite of install_skip_reason's
# doubt-installs: an unreadable archive is never evidence of a build.
function archive_payload_ok -a archive
    pacman -Qp -- "$archive" >/dev/null 2>&1
end

# freshness_skip_decision PKG_PATH PACKAGE_ID SKIP_MODE — THE skip decision.
# Both claim sites (build_package's skip block and the toolchain pre-check
# before a drift clean) call this one function; the two copies that used to
# live at those sites had already diverged once. SKIP_MODE is build_package's
# skip_flag (in-params are arguments here, like every other caller seam):
#   1 = -s           the full freshness analysis below
#   2 = --skip-built the built-set claim only — no PKGBUILD-vs-archive mtime
#                    compare, no VCS probes (this function must not touch the
#                    network in that mode), no waivers (nothing to waive)
# Results:
#   _FRESHNESS_VERDICT  skip | build | defer
#   _FRESHNESS_ARCHIVE  the current set (skip verdict only)
#   _FRESHNESS_WAIVER   waiver line(s) — printed only by an actual skip claim
#   _FRESHNESS_WAIVER_REASON  the claim token when the skip carries one
#                             (freshness-waived / abi-provider-waived /
#                             skip-built)
# skip  = the COMPLETE current-version set is payload-valid and, in -s mode,
#         every member is at least as new as the PKGBUILD (nanosecond mtimes:
#         makepkg writes all outputs of one build together, so a mixed-age set
#         is itself evidence of an interrupted build) and every member is
#         VCS-current or under a recorded waiver. In --skip-built mode the
#         complete payload-valid set IS the claim.
# build = anything else; the reason is already reported, except the silent
#         "nothing is current" case.
# defer = freshness unverifiable and the consumer chain can absorb the wait
#         (_DEFER_REASON set for the run record). --skip-built never defers —
#         it never probes, so there is nothing to be unverifiable.
function freshness_skip_decision -a pkg_path package_id skip_mode
    set -g _FRESHNESS_VERDICT build
    set -g _FRESHNESS_ARCHIVE
    set -l pkg_name "$package_id"
    set -l archives (current_archives "$pkg_path")
    switch $status
        case 0
            # Complete set — fall through to the gates below.
        case 1 3
            # Nothing current (1) or discovery unestablished (3): build. An
            # evaluation failure already named itself on stderr.
            return 0
        case '*'
            # Anomaly, not routine rebuild noise: a half-written split set is
            # exactly what used to pass silently, so it is reported even in
            # quiet/piped output (like the evaluation error below).
            ui_info "$pkg_name: built output set is incomplete (missing: "(string join ' ' $_CURRENT_ARCHIVES_MISSING)") — rebuilding"
            return 0
    end
    if test "$skip_mode" != 2
        for archive in $archives
            # `test -nt` compares nanosecond mtimes; a PKGBUILD newer than any
            # member means the whole set predates the recipe. --skip-built
            # deliberately drops this gate: a git pull that only touches the
            # recipe's mtime is not evidence the built set is stale.
            if test "$pkg_path/PKGBUILD" -nt "$archive"
                return 0
            end
        end
    end
    for archive in $archives
        if not archive_payload_ok "$archive"
            ui_info "$pkg_name: "(basename -- "$archive")" cannot be read as a package archive (interrupted write?) — rebuilding"
            return 0
        end
    end
    if test "$skip_mode" = 2
        # The --skip-built claim: a complete, payload-valid current-version set
        # is the evidence — freshness analysis stops here. The reason rides the
        # lane wire so the run-record row says skip-built, never a bare ok (a
        # freshness-blind skip is a different claim from an untouched archive).
        set -g _FRESHNESS_WAIVER
        set -g _FRESHNESS_WAIVER_REASON skip-built
        set -g _FRESHNESS_ARCHIVE $archives
        set -g _FRESHNESS_VERDICT skip
        return 0
    end
    set -l waiver_lines
    for archive in $archives
        vcs_archive_is_current "$pkg_path" "$archive"
        set -l freshness_status $status
        set -a waiver_lines $_FRESHNESS_WAIVER
        if test $freshness_status -eq 2
            # rc 2 = freshness cannot be established (transport retries
            # exhausted inside the query). Owner semantics (2026-10-02): -s may
            # skip ONLY on verified-unchanged. Unverifiable parks the recipe
            # ONLY when its consumer chain can absorb the wait (few or no
            # waiters); else it falls back to a normal build attempt. Never fail.
            ui_error "$pkg_name: --skip cannot verify upstream VCS freshness: $_VCS_REVISION_ERROR"
            switch (unverifiable_defer_plan "$package_id")
                case defer
                    set -g _DEFER_REASON upstream-unverified
                    ui_error "$pkg_name: consumer chain can absorb the wait — parking this recipe (deferred)"
                    echo "  Nothing was built or installed; dependents wait (waits-on-deferred)."
                    set -g _FRESHNESS_VERDICT defer
                    return 0
                case '*'
                    ui_error "$pkg_name: consumers cannot wait — falling back to a normal build attempt"
                    return 0
            end
        end
        if test $freshness_status -ne 0
            if test $freshness_status -eq 3
                # A missing/mismatched baseline or a manifest bound to
                # different archive bytes is state corruption, not routine
                # rebuild noise — reported even in quiet/piped output.
                ui_info "$pkg_name: $_VCS_REVISION_ERROR; rebuilding once to record a baseline"
            else if test "$_BUILD_QUIET" != "1"
                ui_info "$pkg_name: upstream VCS ref moved; rebuilding"
            end
            return 0
        end
    end
    set -g _FRESHNESS_WAIVER $waiver_lines
    set -g _FRESHNESS_ARCHIVE $archives
    set -g _FRESHNESS_VERDICT skip
    return 0
end

# ─── List built package files for a PKGBUILD (all splits, current version) ───
# Multi-split packages (e.g. linux-firmware) produce several *.pkg.tar.zst —
# "ls -t | head -1" would install only one split. Discovery is current_archives:
# expected outputs at the evaluated pkgver-pkgrel only, and a partial set
# prints NOTHING — installing a subset of a split package is exactly the
# silent-wrong claim this seam refuses. The missing outputs are named on
# stderr so a command-substitution caller still learns why its list is empty.
# Damaged discovery additionally records a named refusal row (refuse
# partial-set / refuse discover-failed) in _GSA_DISCOVER_REFUSALS — install_plan
# consumes them, so the single-transaction entries refuse a shrunken set
# instead of installing the evaluable subset (R-F25 + the follow-up row).
function list_split_pkgs -a pkg_path
    set -q _GSA_DISCOVER_REFUSALS; or set -g _GSA_DISCOVER_REFUSALS
    set -l archives (current_archives "$pkg_path")
    switch $status
        case 0
            printf '%s\n' $archives
        case 2
            ui_warning "$(basename "$pkg_path"): built output set is incomplete (missing: "(string join ' ' $_CURRENT_ARCHIVES_MISSING)") — excluded from discovery; rebuild before installing" >&2
            set -a _GSA_DISCOVER_REFUSALS (plan_row refuse partial-set "$pkg_path" $_CURRENT_ARCHIVES_MISSING)
        case 3
            ui_warning "$(basename "$pkg_path"): archive discovery could not be established (pkgver/pkgrel unusable) — excluded from discovery; fix the recipe before installing" >&2
            set -a _GSA_DISCOVER_REFUSALS (plan_row refuse discover-failed "$pkg_path")
    end
    return 0
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
    # The PGO gate needs both: tar unrolls the archive, strings reads it;
    # readelf arms the post-install NEEDED probe (R-F26: a probe that cannot
    # run must be a preflight refusal, never a silent "clean").
    if not require_command tar; or not require_command strings; or not require_command readelf
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
        # PKGBUILD's current evaluated pkgver-pkgrel — but a DAMAGED recipe is
        # still enumerated by name here (R-F25): "install everything" must
        # never shrink without a named omission. The empty-set contract (no
        # refusal, no transaction) is pinned by tests/install-archive-guard.sh
        # cases J/K and S3.
        for row in $_GSA_DISCOVER_REFUSALS
            set -l fields (plan_row_fields "$row")
            if test "$fields[2]" = partial-set
                ui_warning "omitted from the transaction: "(basename "$fields[3]")" — built output set is incomplete (missing: "(string join ' ' $fields[4..-1])")"
            else
                ui_warning "omitted from the transaction: "(basename "$fields[3]")" — archive discovery could not be established (pkgver/pkgrel unusable)"
            end
        end
        set -g _GSA_DISCOVER_REFUSALS
        ui_warning "No eligible built packages found."
        return 0
    end
    # The plan is computed once and consumed by the executor (silent: the
    # heading below is the only plan rendering this entry adds). A damaged
    # discovery refuses the plan rows (R-F25) — the single transaction may
    # not install the shrunken set.
    set -l plan (install_plan force $pkgs)
    set -l plan_status $status
    if test $plan_status -ne 0; and test (count $plan) -eq 0
        # F39: a FAILED plan must never render as "nothing to do" (see
        # install_pkgs_now).
        set plan (plan_row refuse plan-failed)
    end
    if test $plan_status -eq 0
        ui_heading "Installing "(count $pkgs)" packages"
        for p in $pkgs
            echo "  $p"
        end
    end
    # $pkgs are absolute (find_pkg_dirs → $SCRIPT_DIR) — safe under any cwd.
    if not ensure_state_dirs
        return 1
    end
    set -l install_log "$LOG_DIR/install-all.log"
    install_execute "$install_log" loud (count $argv) $argv $plan
end

# ─── ABI-drift guard (the five layers) ──────────────────────────────────────
# A Class A `-git` library's soname bump must never silently break installed
# consumers. Five layers, one shared vocabulary (tests/abi-*.sh pin them):
#
#   1. closure lint  (audit_lint_abi_closure, --audit / --audit-lint
#      abi-closure, report-only): every workspace recipe shipping ELF libs
#      must carry bare soname provides (`libfoo.so`, auto-versioned by
#      makepkg); every DT_NEEDED soname of a workspace-built output must
#      resolve to (a) a workspace package's provides, (b) an expected
#      base-system lib (abi_base_lib_ok), or (c) a name registered in the
#      exception registry (config/abi-exclusions.conf). Violations name the
#      provider/consumer pair.
#   2. batch gate tightening (the coupled-batch gate in main): a provider
#      whose soname-provides set changed against the installed stock package's
#      provides drags its FULL in-tree consumer closure into the batch —
#      an installed member omitted from the selection is refused. Pure gate
#      logic: committed .SRCINFO provides + config/topology.conf, no builds.
#   3. install-time fatal provide-diff refusal (abi_provide_refusals, an
#      install-plan step alongside pgo_payload_refusals, BEFORE the force
#      branch): when an archive's .PKGINFO bare soname provides disappear or
#      change against the installed database's provides for the same pkgname
#      — or, when the pkgname is not installed, for its abi_stock_name
#      counterpart (the Stock→house swap: the surface MOVES to a new pkgname,
#      it does not vanish) — and the consumer closure is not fully included
#      in the transaction, silent `refuse abi-*` rows abort before any
#      pacman -U.
#   4. post-install NEEDED probe (install_needed_probe, after a successful
#      transaction): every installed consumer output's DT_NEEDED must resolve
#      within the newly installed + existing provide set; unresolved sonames
#      abort loudly, named.
#   5. exposure audit (audit_lint_abi_exposure, --audit / --audit-lint
#      abi-exposure, report-only): the provider → exposed-consumer mapping for
#      every workspace lib whose soname provides differ from the installed
#      stock equivalent.
#
# Resolution vocabulary (layers 1/4): a soname resolves to (a) a provide some
# workspace package declares (abi_provide_covers: a bare stem covers its
# family, makepkg's auto-versioned form covers its exact version — that
# precision is what turns a silent soname bump into a named violation),
# (b) an expected base-system soname (abi_base_lib_ok), (c) an exception
# documented in config/abi-exclusions.conf (abi_excluded — the registry is
# wired in read_abi_exclusions, loaded on EVERY invocation), or (d) for the
# post-install probe only, runtime file truth: the named file is shipped by
# the transaction or owned by an installed package (install_needed_probe's
# `_PROBESHIP_`/`pacman -Ql` half — stock Arch providers such as libx11 ship
# no soname provide, and the dynamic linker resolves their files regardless).
#
# Stock convention (layers 2/5): the "installed stock equivalent" of a
# workspace pkgname is what the installed database answers for the name with
# its VCS suffix stripped (abi_stock_name — the same swap counterpart
# audit_lint_swap uses). `pacman -Qi <stock>` resolves through provides, so
# the query reaches whatever currently provides the stock name: the stock
# package before the swap, the house build after it.

# abi_stock_name NAME → the stock counterpart of a pkgname: the name with a
# VCS suffix (-git/-svn/-hg/-snapshot) stripped, or NAME itself.
function abi_stock_name -a name
    string replace -r -- '-(git|svn|hg|snapshot)$' '' "$name"
end

# abi_provide_name ENTRY → the name part of a provide/depend entry
# ('libfoo.so=1-64' → 'libfoo.so', 'meson>=1.8' → 'meson').
function abi_provide_name -a entry
    set -l name (string replace -r -- '[=<>].*$' '' "$entry")
    string trim -- "$name"
end

# abi_provide_covers ENTRY SONAME → 0 when provide ENTRY satisfies the
# DT_NEEDED SONAME. Exact names always match. A bare-stem provide
# ('libfoo.so') covers the whole family ('libfoo.so.N'); makepkg's
# auto-versioned form ('libfoo.so=1-64', generated from soname 'libfoo.so.1')
# covers only its own version — so a bumped consumer NEEDED no longer resolves
# to the old provider and the violation can name both sides.
function abi_provide_covers -a entry soname
    set -l pp (string split -m 1 '=' -- "$entry")
    set -l name (string trim -- "$pp[1]")
    test -n "$name"; or return 1
    test "$name" = "$soname"; and return 0
    set -l stem (_lint_soname_stem "$soname")
    if test (count $stem) -ge 1; and test "$name" = "$stem"
        if test (count $pp) -lt 2; or test -z "$pp[2]"
            return 0
        end
        set -l v (string replace -r -- '-[^-]+$' '' "$pp[2]")
        test "$soname" = "$name.$v"; and return 0
    end
    return 1
end

# abi_soname_stems ENTRIES... → the bare soname stems of soname-shaped
# provide names (the layer-2/5 comparison unit: a family rename moves the
# stem set, an in-place version bump moves only makepkg's auto-version —
# which is layer 3's exact-diff job).
function abi_soname_stems
    for value in $argv
        set -l name (abi_provide_name "$value")
        set -l stem (_lint_soname_stem "$name")
        test (count $stem) -ge 1; or continue
        printf '%s\n' $stem[1]
    end
    return 0
end

# abi_base_lib_ok SONAME → 0 for an expected base-system soname: the glibc +
# gcc-libs runtime every Arch system carries (`base` depends on both). Any
# other non-workspace soname must be registered in the exclusions registry.
function abi_base_lib_ok -a soname
    contains -- "$soname" \
        libc.so.6 libm.so.6 libmvec.so.1 libdl.so.2 libpthread.so.0 librt.so.1 \
        libresolv.so.2 libutil.so.1 libnsl.so.1 libthread_db.so.1 \
        ld-linux-x86-64.so.2 ld-linux.so.2 ld64.so.2 \
        libgcc_s.so.1 libstdc++.so.6 libgomp.so.1 libatomic.so.1 libquadmath.so.0
end

# abi_excluded NAME → 0 when the documented exception registry covers this
# package id or this soname name/stem (config/abi-exclusions.conf).
function abi_excluded -a name
    contains -- "$name" $_ABI_EXCLUSION_IDS; and return 0
    set -l stem (_lint_soname_stem "$name")
    if test (count $stem) -ge 1
        contains -- "$stem" $_ABI_EXCLUSION_IDS; and return 0
    end
    return 1
end

# abi_package_srcinfo ID → the committed .SRCINFO path of a workspace id.
function abi_package_srcinfo -a id
    set -l pkg_path (package_path "$id")
    test -n "$pkg_path"; or return 1
    printf '%s\n' "$pkg_path/.SRCINFO"
    return 0
end

# srcinfo_pkgnames SRCINFO → pkgbase + pkgname outputs (deduped).
function srcinfo_pkgnames -a srcinfo
    sed -n 's/^pkgbase = //p; s/^pkgname = //p' "$srcinfo" 2>/dev/null | awk '!seen[$0]++'
end

# srcinfo_output_names SRCINFO → the pkgname OUTPUTS only (no pkgbase): the
# names built archives actually carry. A recipe whose pkgbase differs from its
# outputs must never demand — or bless — an archive named after the pkgbase;
# srcinfo_pkgnames answers a different question (installed-name probes).
function srcinfo_output_names -a srcinfo
    sed -n 's/^pkgname = //p' "$srcinfo" 2>/dev/null | awk '!seen[$0]++'
end

# srcinfo_provides SRCINFO → every `provides = ` value (all sections).
function srcinfo_provides -a srcinfo
    sed -n 's/^[[:space:]]*provides[[:space:]]*=[[:space:]]*//p' "$srcinfo" 2>/dev/null
end

# abi_installed_provides NAME → the installed database's provide entries for
# NAME (LANG=C pins the field layout, like install_skip_reason's queries).
# pacman resolves NAME through provides, so the stock counterpart query
# reaches whatever currently provides the stock name.
function abi_installed_provides -a name
    # Memoised per name (per process): the gate probes every selected
    # provider's names and the same names repeat across probes — each cached
    # hit is one saved `pacman -Qi` fork. The cache reflects the installed
    # database as of the first query; install_execute clears it right after a
    # transaction so nothing later reads pre-install state.
    set -l cache_key _ABIPROV_(_topo_key "$name")
    set -l ready_key _ABIPROVREADY_(_topo_key "$name")
    if set -q $ready_key
        if set -q $cache_key
            set -l cached $$cache_key
            test (count $cached) -gt 0; and printf '%s\n' $cached
        end
        return 0
    end
    set -l lines (LANG=C pacman -Qi -- "$name" 2>/dev/null)
    test (count $lines) -gt 0; or begin
        set -g $ready_key 1
        return 0
    end
    set -l values
    for line in $lines
        set -l m (string match -r -g '^[[:space:]]*Provides[[:space:]]*:[[:space:]]*(.*)$' -- "$line")
        if test (count $m) -lt 1
            set m (string match -r -g '^[[:space:]]*Provides As[[:space:]]*:[[:space:]]*(.*)$' -- "$line")
        end
        test (count $m) -ge 1; and set -a values (string split -n ' ' -- (string replace -a \t ' ' -- $m[1]))
    end
    set -l out
    for value in $values
        test "$value" = None; and continue
        set -a out "$value"
    end
    if test (count $out) -gt 0
        set -g $cache_key $out
        printf '%s\n' $out
    end
    set -g $ready_key 1
    return 0
end

# abi_installed_cache_clear — drop the per-process installed-database memos
# (abi_installed_provides / abi_pkg_installed / the gate's id probes). Called
# right after a pacman transaction lands: every later answer must reflect the
# NEW database, not the pre-install snapshot the plan consulted.
function abi_installed_cache_clear
    set -l stale (set -n | string match -r '^_(?:ABIPROV|ABIPROVREADY|ABIQ|ABIQREADY|ABIQID|ABIQIDREADY)_.*$')
    if test (count $stale) -gt 0
        set -e $stale
    end
end

# _abi_provides_chunk NAME... → "NAME|provide-entry" rows for one chunk, or a
# non-zero status when the batched form is not provably the per-name form.
# pacman resolves each bare target through provides exactly like the
# single-name query and prints one record per resolved target IN TARGET ORDER
# (verified on pacman 7.1: `pacman -Qi -- java-runtime jdk-openjdk` prints the
# provider's record twice — one record per target, never deduped), so the
# batch output zips back onto the target list minus the names stderr reports
# as not found. The zip is only trusted when every piece lines up: only
# not-found errors on stderr, one record per resolved target, and each record
# either named for its target or carrying it as a provide — anything else
# reports divergence and the caller reruns the chunk per name (the exact
# behaviour this batches).
function _abi_provides_chunk
    set -l tmp_root "$TMPDIR"
    if test -z "$tmp_root"
        set tmp_root /tmp
    end
    set -l work (mktemp -d "$tmp_root/gsa-abi-batch.XXXXXX" 2>/dev/null)
    test -n "$work"; or return 1
    LANG=C pacman -Qi -- $argv 2>"$work/err" >"$work/out"
    set -l awk_rc 0
    # The record side is first (ARGV[1]) because the standard FNR==NR
    # two-file trick misfires when the error file is empty.
    set -l target_str (string join ' ' $argv)
    awk -v targets="$target_str" '
        BEGIN { rec = -1; newrec = 1 }
        FILENAME == ARGV[1] {
            if ($0 == "") { newrec = 1; next }
            if (newrec || rec < 0) { rec++; newrec = 0 }
            if ($0 ~ /^[ \t]*Name[ \t]*:[ \t]*/) {
                v = $0
                sub(/^[ \t]*Name[ \t]*:[ \t]*/, "", v)
                gsub(/^[ \t]+|[ \t]+$/, "", v)
                rname[rec] = v
                next
            }
            if ($0 ~ /^[ \t]*Provides As[ \t]*:[ \t]*/) {
                v = $0
                sub(/^[ \t]*Provides As[ \t]*:[ \t]*/, "", v)
                gsub(/\t/, " ", v)
                rprov[rec] = rprov[rec] " " v
                next
            }
            if ($0 ~ /^[ \t]*Provides[ \t]*:[ \t]*/) {
                v = $0
                sub(/^[ \t]*Provides[ \t]*:[ \t]*/, "", v)
                gsub(/\t/, " ", v)
                rprov[rec] = rprov[rec] " " v
                next
            }
            next
        }
        {
            if ($0 == "") next
            if ($0 ~ /^error: package .+ was not found$/) {
                e = $0
                sub(/^error: package ./, "", e)
                sub(/. was not found$/, "", e)
                missed[e] = 1
                next
            }
            bad = 1
        }
        END {
            if (bad) exit 3
            n = split(targets, T, " ")
            resolved = 0
            for (i = 1; i <= n; i++) if (!(T[i] in missed)) resolved++
            if (rec + 1 != resolved) exit 3
            ri = 0
            for (i = 1; i <= n; i++) {
                t = T[i]
                if (t in missed) continue
                ok = (rname[ri] == t)
                m = split(rprov[ri], p, " ")
                for (j = 1; j <= m && !ok; j++) {
                    q = p[j]
                    sub(/[=<>].*$/, "", q)
                    gsub(/^[ \t]+|[ \t]+$/, "", q)
                    if (q == t) ok = 1
                }
                if (!ok) exit 3
                for (j = 1; j <= m; j++) {
                    if (p[j] == "" || p[j] == "None") continue
                    print t "|" p[j]
                }
                ri++
            }
        }' "$work/out" "$work/err"
    set awk_rc $status
    command rm -rf -- "$work"
    return $awk_rc
end

# abi_installed_provides_batch NAME... → "NAME|provide-entry" rows for every
# queried name (duplicates collapsed), computed in ONE `pacman -Qi` per
# 256-name chunk instead of one fork per name — the exposure lint queried 649
# stock names at ~74 ms per fork (~48 s). Entries are the raw provide strings
# ('libfoo.so=1-64'), `None` skipped — identical to abi_installed_provides,
# which stays the per-name primitive (the install/batch paths) and is the
# fallback whenever a chunk's batch form diverges.
function abi_installed_provides_batch
    set -l names (printf '%s\n' $argv 2>/dev/null | awk '!seen[$0]++')
    set -l total (count $names)
    set -l first 1
    while test $first -le $total
        set -l last (math $first + 255)
        test $last -gt $total; and set last $total
        set -l chunk $names[$first..$last]
        set -l rows (_abi_provides_chunk $chunk)
        if test $status -ne 0
            set rows
            for name in $chunk
                for value in (abi_installed_provides "$name")
                    set -a rows "$name|$value"
                end
            end
        end
        test (count $rows) -gt 0; and printf '%s\n' $rows
        set first (math $last + 1)
    end
    return 0
end

# abi_pkg_installed ID → 0 when any output of the workspace package is
# installed (the batch gate's "nothing to protect" rule reads this).
function abi_pkg_installed -a id
    # Memoised per workspace id (see abi_installed_provides): the batch gate
    # probes the same members once per changed provider.
    set -l ready_key _ABIQREADY_(_topo_key "$id")
    if set -q $ready_key
        test "$$ready_key" = 1; and return 0
        return 1
    end
    set -l names $id
    set -l srcinfo (abi_package_srcinfo "$id")
    if test -n "$srcinfo"; and test -f "$srcinfo"
        set names (srcinfo_pkgnames "$srcinfo")
        test (count $names) -gt 0; or set names $id
    end
    for name in $names
        pacman -Q -- "$name" >/dev/null 2>&1; and begin
            set -g $ready_key 1
            return 0
        end
    end
    set -g $ready_key 0
    return 1
end

# abi_id_installed ID → memoised `pacman -Q <id>` (the tag batch gate's
# installed-member probe; first query forks exactly like the direct call it
# replaced — `pacman -Q NAME`, NO `--`: the fixture stubs that answer this
# probe read argv positionally).
function abi_id_installed -a id
    set -l ready_key _ABIQIDREADY_(_topo_key "$id")
    if set -q $ready_key
        test "$$ready_key" = 1; and return 0
        return 1
    end
    if pacman -Q "$id" >/dev/null 2>&1
        set -g $ready_key 1
        return 0
    end
    set -g $ready_key 0
    return 1
end

# abi_name_edges → provider|consumer pairs from the committed .SRCINFO files:
# consumer C names provider P when a build-time field of C (depends,
# makedepends, optdepends, checkdepends) names any name P's surface carries
# (pkgbase, pkgname or provide name). The .SRCINFO half of the closure
# relation; config/topology.conf's edges are the other (see
# abi_consumer_closure). One sorted pass, then one awk join — never a nested
# fish loop over every pair.
function abi_name_edges
    # ONE shared .SRCINFO parse (srcinfo_rows) replaces the six sed forks per
    # recipe. The tagged-row → S/P/A walk is one awk over the row stream — the
    # old fish `for row in (srcinfo_rows)` re-marshalled every row (~40k at
    # scale) through `string split` on EACH call, and this ran once per changed
    # provider through abi_consumer_closure. The result is memoised per
    # process: the committed .SRCINFOs are static within a caller's window
    # (version sync rewrites them BEFORE any ABI consumer runs in a lane).
    # Row values keep everything after their fixed separator count (the old
    # `string split -m 3` semantics), so a value containing '|' survives.
    if set -q _ABI_NAME_EDGES_READY
        test (count $_ABI_NAME_EDGES) -gt 0; and printf '%s\n' $_ABI_NAME_EDGES
        return 0
    end
    set -g _ABI_NAME_EDGES (srcinfo_rows | awk -F'|' '
        function field_rest(s, n,   i, p) {
            p = 1
            for (i = 1; i <= n; i++) {
                p = index(s, "|")
                if (p == 0) return ""
                s = substr(s, p + 1)
            }
            return s
        }
        {
            tag = $1
            if (tag == "B" || tag == "N") {
                v = field_rest($0, 2)
                if (v != "") print "S|" v "|" $2
            } else if (tag == "P") {
                print "P|" field_rest($0, 3) "|" $2
            } else if (tag == "D") {
                print "A|" field_rest($0, 3) "|" $2
            }
        }' | awk -F'|' '
        function norm(x) {
            sub(/[=<>].*$/, "", x)
            gsub(/^[ \t\r\n\f\v]+|[ \t\r\n\f\v]+$/, "", x)
            return x
        }
        $1 == "S" { if ($2 != "") print "S|" $2 "|" $3; next }
        $1 == "P" { n = norm($2); if (n != "") print "S|" n "|" $3; next }
        { v = $2; sub(/:.*/, "", v)
          gsub(/^[ \t\r\n\f\v]+|[ \t\r\n\f\v]+$/, "", v)
          n = norm(v)
          if (n != "") print "A|" n "|" $3 }
    ' | sort -t '|' -k 2,2 | awk -F'|' '
        function flush(   s, a) {
            for (s in prov) for (a in cons) if (prov[s] != cons[a]) print prov[s] "|" cons[a]
            delete prov
            delete cons
        }
        $2 != last { flush(); last = $2 }
        { if ($1 == "S") prov[$3] = $3; else cons[$3] = $3 }
        END { flush() }
    ')
    set -g _ABI_NAME_EDGES_READY 1
    # Provider → consumer adjacency from the name edges, keyed (order per
    # provider preserved: the edges are appended in stream order). Built here
    # so abi_consumer_closure's BFS is O(closure) instead of scanning the
    # whole edge list per visited node.
    set -l stale (set -n | string match -r '^_ABICONS_.*$')
    if test (count $stale) -gt 0
        set -e $stale
    end
    for edge in $_ABI_NAME_EDGES
        set -l parts (string split -m 1 '|' -- "$edge")
        set -ga _ABICONS_(_topo_key "$parts[1]") "$parts[2]"
    end
    test (count $_ABI_NAME_EDGES) -gt 0; and printf '%s\n' $_ABI_NAME_EDGES
    return 0
end

# abi_consumer_closure PROVIDER... → the FULL in-tree consumer closure of the
# provider ids: every workspace package transitively consuming one of them,
# over BOTH relations — the topology reverse adjacency (_CONSUMER_INDEX from
# config/topology.conf) and the committed .SRCINFO name matching
# (abi_name_edges). Pure gate logic: no builds, no pacman, no network. The
# providers themselves are never output.
function abi_consumer_closure
    set -l seeds $argv
    test (count $seeds) -gt 0; or return 0
    # Builds the memoised name-edge stream + its keyed provider→consumer map
    # (_ABICONS_) once; the BFS below is O(closure) over keyed adjacency.
    # The old version scanned $_CONSUMER_INDEX AND the whole name-edge list
    # per visited package — O(V·E) string splits per call — and re-parsed
    # every .SRCINFO row per call.
    abi_name_edges >/dev/null
    set -l visited
    set -l queue $seeds
    set -l qhead 1
    # CACHED queue length: `count $queue` in the loop head expands the WHOLE
    # queue into argv every iteration (fish `count` is O(1), its ARGV is not)
    # — 38 s of self time across the two largest real closures (profile
    # 2026-10-05). The queue only grows at the two appends below, so qlen is
    # maintained there.
    set -l qlen (count $queue)
    while test $qhead -le $qlen
        set -l pkg $queue[$qhead]
        set qhead (math $qhead + 1)
        set -l key (_topo_key "$pkg")
        set -l seen_var _ABICLSEEN_$key
        if set -q $seen_var
            continue
        end
        set -f $seen_var 1
        set -a visited $pkg
        set -l cons_var _TCONS_$key
        if set -q $cons_var
            set -l cons $$cons_var
            set -a queue $cons
            set qlen (math $qlen + (count $cons))
        end
        set -l name_var _ABICONS_$key
        if set -q $name_var
            set -l ncons $$name_var
            set -a queue $ncons
            set qlen (math $qlen + (count $ncons))
        end
    end
    for pkg in $visited
        contains -- "$pkg" $seeds; and continue
        printf '%s\n' "$pkg"
    end
    return 0
end

# abi_soname_provides_changed ID → 0 when the workspace recipe's soname
# provides (committed .SRCINFO, bare stems) differ from the installed stock
# equivalent's provides (the stem sets). Layer 2's batch trigger: only a
# changed surface can strand consumers. Nothing installed to compare against
# means nothing to protect — never changed.
function abi_soname_provides_changed -a id
    set -l srcinfo (abi_package_srcinfo "$id")
    if test -z "$srcinfo"; or not test -f "$srcinfo"
        return 1
    end
    set -l house (abi_soname_stems (srcinfo_provides "$srcinfo"))
    test (count $house) -gt 0; or return 1
    set -l names (srcinfo_pkgnames "$srcinfo")
    test (count $names) -gt 0; or set names $id
    set -l installed
    set -l compared 0
    for name in $names
        set -l entries (abi_installed_provides (abi_stock_name "$name"))
        test (count $entries) -gt 0; or continue
        set compared 1
        set -a installed (abi_soname_stems $entries)
    end
    test $compared -eq 1; or return 1
    for stem in $house
        contains -- "$stem" $installed; or return 0
    end
    for stem in $installed
        contains -- "$stem" $house; or return 0
    end
    return 1
end

# abi_package_id_for_pkgname NAME → the workspace id whose committed
# .SRCINFO outputs NAME (used to find a consumer closure from an archive's
# own .PKGINFO — never from the path spelling the caller happened to pass).
function abi_package_id_for_pkgname -a name
    # D-F4: answers from the ONE name surface (_pkgname_index), not a private
    # per-recipe scan — a name resolves to the same recipe everywhere.
    _pkgname_owner "$name"
end

# archive_pkginfo ARCHIVE → the archive's .PKGINFO content (empty when the
# payload is unreadable). Member names differ across packers ('.PKGINFO' vs
# './.PKGINFO'), so the member is listed first and read by name.
function archive_pkginfo -a archive
    set -l member (tar -tf "$archive" 2>/dev/null \
        | awk '$0 == ".PKGINFO" || $0 == "./.PKGINFO" { print; exit }')
    test -n "$member"; or return 1
    tar -xOf "$archive" -- "$member" 2>/dev/null
    return $status
end

# ─── Layer 3: install-time fatal provide-diff refusal (install-plan step) ────
# For each archive destined for install, compare its .PKGINFO provides against
# the installed database's provides for the same pkgname — or, when the
# archive's pkgname is NOT installed, against the provides of its stock
# counterpart (abi_stock_name: the VCS suffix stripped). The counterpart path
# is the Stock→house swap (run #31, 2026-10-06: bzip2-git replaced installed
# stock bzip2 whose `libbz2.so=1.0-64` provide every consumer depended on,
# while the build auto-versioned `libbz2.so=1-64`): the surface MOVES to a
# new pkgname instead of vanishing, so "nothing installed for this pkgname"
# is not evidence that nothing can disappear. `pacman -Qi <stock>` resolves
# through provides to whatever carries the stock name today — the stock
# package before the swap. A BARE soname
# provide (auto-versioned by makepkg: `libfoo.so=1-64`) that disappears or
# changes version is a soname bump: every installed consumer built against the
# old surface breaks the moment pacman -U lands. If the consumer closure is
# not fully included in the transaction, the plan refuses — silently here
# (the decision half never renders); install_execute renders the rows, and the
# --install-decide seam prints them verbatim. Runs BEFORE the force branch:
# -fi/-ia bypass the same-version SKIP, never this gate. Tolerance on what it
# cannot read (the locked decision — fail-closed on unreadable .PKGINFO was
# rejected: the existing battery's stub makepkg emits empty archives and its
# pinned contracts demand a pacman-free plan for them): an archive with no
# readable .PKGINFO is skipped WITHOUT consulting pacman (install-conflict-ask
# C1/C2 and install-archive-guard I5 pin zero pacman calls on those paths).
# A READABLE .PKGINFO that carries no provides is the provide-disappears case
# and still refuses below. Only nothing installed for the name AND nothing
# installed for the stock counterpart means nothing can disappear (a fresh
# install cannot orphan consumers of a surface that never existed) — that
# double-negative is probed with one extra read-only `pacman -Qi <stock>`;
# a pkgname with no VCS suffix has no counterpart and keeps the one-probe
# fresh-install path. A swap whose bare soname provides match the
# counterpart's exactly is a clean pass.
#
# "Fully included in the transaction" counts the INSTALLED part of the
# consumer closure (an uninstalled consumer has nothing to protect — the
# batch gate's standing rule); a member counts as included when any of its
# outputs is among the transaction's pkgnames. Consumers of an archive whose
# pkgname matches no workspace recipe are vacuously covered (no in-tree
# closure to open).
#
# Row shapes (tab-framed through the plan_row codec, mirroring
# pgo_payload_refusals):
#   refuse abi-soname <archive> <pkgname> <provide-name> <installed-ver> <built-ver>
#   refuse abi-consumer <archive> <consumer>
# (<built-ver> is '-' when the provide disappears entirely.) The Stock→house
# swap path reuses these shapes unchanged (no new row): <pkgname> stays the
# ARCHIVE's pkgname and <installed-ver> comes from the stock counterpart's
# surface — the counterpart is derivable (abi_stock_name <pkgname>) and the
# codec/renderer contract stays 7 fields. Returns 0 for
# every archive that is clean or not comparable, 1 after any refusal row.
function abi_provide_refusals
    # Every pkgname the transaction will install — the closure-coverage side.
    set -l tx_names
    for archive in $argv
        for line in (archive_pkginfo "$archive")
            set -l h (string match -r -g '^pkgname = (.+)$' -- "$line")
            test (count $h) -ge 1; and set -a tx_names $h[1]
        end
    end
    set -l rows
    for archive in $argv
        set -l pkgname ""
        set -l built_provides
        for line in (archive_pkginfo "$archive")
            set -l h (string match -r -g '^pkgname = (.+)$' -- "$line")
            if test (count $h) -ge 1
                test -z "$pkgname"; and set pkgname $h[1]
                continue
            end
            set -l p (string match -r -g '^[[:space:]]*provides = (.+)$' -- "$line")
            test (count $p) -ge 1; and set -a built_provides $p[1]
        end
        if test -z "$pkgname"
            # Not a readable payload — skip outright (see the tolerance note
            # above): no pacman probe names it, because the plan step must
            # stay pacman-free for unreadable archives.
            continue
        end
        set -l installed (abi_installed_provides "$pkgname")
        if test (count $installed) -eq 0
            # Stock→house swap: the surface moved to this new pkgname, so the
            # comparison target is the stock counterpart's provides (the same
            # comparison unit as the same-pkgname path below). Nothing
            # installed for either name is the only true fresh install.
            set -l stock (abi_stock_name "$pkgname")
            test "$stock" != "$pkgname"; or continue
            set installed (abi_installed_provides "$stock")
            test (count $installed) -gt 0; or continue
        end
        set -l archive_rows
        for entry in $installed
            set -l name (abi_provide_name "$entry")
            # "bare soname provide": an auto-versioned bare stem — the surface
            # makepkg generates from a shipped DT_SONAME.
            string match -q '*.so' -- "$name"; or continue
            set -l inst_ver ""
            set -l ep (string split -m 1 '=' -- "$entry")
            test (count $ep) -ge 2; and set inst_ver "$ep[2]"
            set -l matched 0
            set -l built_ver ""
            for b in $built_provides
                test (abi_provide_name "$b") = "$name"; or continue
                set matched 1
                set -l bp (string split -m 1 '=' -- "$b")
                test (count $bp) -ge 2; and set built_ver "$bp[2]"
            end
            if test $matched -eq 0
                set -a archive_rows (plan_row refuse abi-soname "$archive" "$pkgname" "$name" "$inst_ver" -)
            else if test "$built_ver" != "$inst_ver"
                set -a archive_rows (plan_row refuse abi-soname "$archive" "$pkgname" "$name" "$inst_ver" "$built_ver")
            end
        end
        test (count $archive_rows) -gt 0; or continue
        # The refusal is conditional: a provide change whose consumer closure
        # is fully covered by the transaction lands safely together.
        set -l provider_id (abi_package_id_for_pkgname "$pkgname")
        set -l open
        if test -n "$provider_id"
            for member in (abi_consumer_closure "$provider_id")
                set -l srcinfo (abi_package_srcinfo "$member")
                set -l names $member
                if test -n "$srcinfo"; and test -f "$srcinfo"
                    set names (srcinfo_pkgnames "$srcinfo")
                    test (count $names) -gt 0; or set names $member
                end
                set -l covered 0
                for name in $names
                    contains -- "$name" $tx_names; and set covered 1
                end
                test $covered -eq 1; and continue
                # The installed-state probe goes through the memoized helper
                # (at most one `pacman -Q` per output name per process) — the
                # raw per-name fork here re-probed every closure member's
                # outputs on every refusal-path install.
                abi_pkg_installed "$member"; or continue
                set -a open "$member"
            end
        end
        test (count $open) -gt 0; or continue
        set -a rows $archive_rows
        for member in $open
            set -a rows (plan_row refuse abi-consumer "$archive" "$member")
        end
    end
    if test (count $rows) -gt 0
        printf '%s\n' $rows | awk '!seen[$0]++'
        return 1
    end
    return 0
end

# ─── Layer 4: post-install NEEDED probe ─────────────────────────────────────
# After a transaction lands, every installed consumer output's DT_NEEDED must
# resolve within the NEWLY INSTALLED + EXISTING provide set (plus the expected
# base-system sonames and the exclusions registry). Failure = loud abort with
# the unresolved sonames named (install_execute renders the rows) — the
# transaction already landed, so the run stops instead of letting every later
# package compile against an unresolvable system.
#
# Reads the transaction's ARCHIVES, not /usr: the probe must be fixture-safe
# and must not depend on where the payload ended up. An archive that cannot be
# extracted after pacman accepted it has no probeable outputs — the probe
# verifies the outputs it can read (a tar failure here is environmental; the
# abort condition is an unresolved NEEDED name, never a missing tool).
#
# Row shapes (tab-framed through plan_row, like every install-plan row):
#   probe-needed <archive> <member> <soname>   (one per unresolved soname)
#   probe-skipped <reason>                     (the probe could not run at all)
# Return: 0 clean, 1 unresolved rows (fatal), 2 skipped (named non-fatal
# warning — the probe never converts "cannot probe" into "clean", R-F26).
function install_needed_probe
    if not command -q tar
        plan_row probe-skipped "tar is not available"
        return 2
    end
    if not command -q readelf
        plan_row probe-skipped "readelf is not available"
        return 2
    end
    set -l tmp_root "$TMPDIR"
    if test -z "$tmp_root"
        set tmp_root /tmp
    end
    set -l work (mktemp -d "$tmp_root/gsa-abi-probe.XXXXXX" 2>/dev/null)
    if test -z "$work"
        plan_row probe-skipped "cannot create a temp dir to probe"
        return 2
    end
    # (a) the newly installed provides, straight from the transaction's
    # .PKGINFO files (makepkg's auto-versioned soname forms).
    set -l provides
    for archive in $argv
        for line in (archive_pkginfo "$archive")
            set -l p (string match -r -g '^[[:space:]]*provides = (.+)$' -- "$line")
            test (count $p) -ge 1; and set -a provides $p[1]
        end
    end
    # (b) the existing set: the installed database's provides, post-transaction.
    # Field-tracked parse of `pacman -Qi`'s full dump — a wrapped Provides
    # continuation must not leak Depends tokens into the provide set.
    set -l cur_field ""
    for line in (LANG=C pacman -Qi 2>/dev/null)
        set -l h (string match -r -g '^[[:space:]]*([A-Za-z][A-Za-z ]*)[[:space:]]*:[[:space:]]*(.*)$' -- "$line")
        if test (count $h) -ge 2
            set cur_field (string trim -- "$h[1]")
            if test "$cur_field" = Provides; or test "$cur_field" = 'Provides As'
                for value in (string split -n ' ' -- (string replace -a \t ' ' -- $h[2]))
                    test "$value" = None; or set -a provides $value
                end
            end
            continue
        end
        if test "$cur_field" = Provides; or test "$cur_field" = 'Provides As'
            for value in (string split -n ' ' -- (string replace -a \t ' ' -- (string trim -- "$line")))
                test -n "$value"; and set -a provides $value
            end
        end
    end
    set -l rows
    set -l n 0
    # Candidate index over the provide set (built once per probe): the cover
    # rule can only match an entry whose name is the soname or its bare stem,
    # so pair selection becomes two keyed lookups per soname instead of an
    # O(sonames × provides) scan — the old shape paid abi_provide_covers (and
    # inside it a stem command substitution — a fork) for EVERY non-matching
    # pair: 24.5 s per probe measured at 8000 provides × 33 sonames. The key
    # is a lossy var-safe digest of the name (non-alphanumerics dropped):
    # equal names always share a key (no real candidate can be missed) and a
    # collision only ADDS candidates that abi_provide_covers then rejects.
    for entry in $provides
        set -l ep (string split -m 1 '=' -- "$entry")
        set -l pname (string trim -- "$ep[1]")
        test -n "$pname"; or continue
        set -f -a _PROVBY_(string replace -a -r '[^A-Za-z0-9]' '' -- "$pname") "$entry"
    end
    # Runtime-file half of resolution (2026-10-06 real full build): a NEEDED
    # name is also resolved when its FILE is on the resulting system — shipped
    # by this transaction, or owned by an installed package. The provide set
    # is the packaging story and stock Arch does NOT mirror it 1:1: libx11,
    # libxt and libxext (among many) ship no `provides=(libX11.so)`, so a
    # provide-only probe aborts every consumer of such a provider although the
    # dynamic linker resolves it fine. The file check is the runtime truth and
    # keeps the true positives: a soname whose file vanished (the icu 78→79
    # class) has neither a provide nor a file and still aborts. The owned-file
    # list is one `pacman -Ql` dump per probe, built lazily on the first
    # provide miss (the fixture stub fabricates it; a failure yields an empty
    # list and the probe stays fail-closed).
    set -l disk_names "$work/disk-names"
    set -l disk_names_ready 0
    for archive in $argv
        set n (math $n + 1)
        set -l dest "$work/$n"
        mkdir -p "$dest"
        tar -xf "$archive" -C "$dest" 2>/dev/null; or continue
        for file in (find "$dest" -type f 2>/dev/null)
            set -l rel (string replace "$dest/" '' -- "$file")
            set -f _PROBESHIP_(string replace -a -r '[^A-Za-z0-9]' '' -- (string replace -r '^.*/' '' -- "$file")) 1
            for soname in (readelf -dW "$file" 2>/dev/null \
                | sed -n 's/^.*NEEDED.*\[\(.*\)\]$/\1/p')
                abi_base_lib_ok "$soname"; and continue
                abi_excluded "$soname"; and continue
                set -l skey (string replace -a -r '[^A-Za-z0-9]' '' -- "$soname")
                set -l stem (_lint_soname_stem "$soname")
                set -l candidates
                set -l map_var _PROVBY_$skey
                set -q $map_var; and set -a candidates $$map_var
                if test (count $stem) -ge 1
                    set -l stem_var _PROVBY_(string replace -a -r '[^A-Za-z0-9]' '' -- "$stem[1]")
                    if test "$stem_var" != "$map_var"
                        set -q $stem_var; and set -a candidates $$stem_var
                    end
                end
                set -l resolved 0
                for entry in $candidates
                    if abi_provide_covers "$entry" "$soname"
                        set resolved 1
                        break
                    end
                end
                if test $resolved -eq 0
                    # Runtime-file half (see the index comment above): bytes
                    # the transaction itself ships resolve for every member.
                    set -q _PROBESHIP_$skey; and set resolved 1
                end
                if test $resolved -eq 0
                    if test $disk_names_ready -eq 0
                        command pacman -Ql 2>/dev/null \
                            | awk '{ p = $0; sub(/^[^ \t]+[ \t]+/, "", p); n = p; sub(/.*\//, "", n); print n }' \
                            | command sort -u > "$disk_names"
                        set disk_names_ready 1
                    end
                    if grep -qxF -- "$soname" "$disk_names" 2>/dev/null
                        set resolved 1
                    end
                end
                test $resolved -eq 1; and continue
                set -a rows (plan_row probe-needed "$archive" "$rel" "$soname")
            end
        end
    end
    command rm -rf -- "$work"
    if test (count $rows) -gt 0
        printf '%s\n' $rows | awk '!seen[$0]++'
        return 1
    end
    return 0
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
# --install-decide fixture seam prints them verbatim. Row shapes (tab-framed
# through the plan_row codec, so a member name containing a space survives
# the consumer):
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
            plan_row refuse pgo-temp "$archive"
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
            command rm -rf -- "$work"
            plan_row refuse pgo-unreadable "$archive" "$tar_rc" "$extracted"
            set failed 1
            continue
        end
        # `strings -f` prefixes every line with its file, so one invocation
        # covers the whole payload and still names the offender. The scan runs
        # from inside $work, so the reported paths are relative to the archive.
        set -l hits (cd "$work"; and find . -type f -exec strings -a -f {} + 2>/dev/null \
            | grep -E '^[^:]+: /[^[:space:]/*][^[:space:]]*\.(gcda|profraw)' \
            | cut -d: -f1 | sort -u)
        command rm -rf -- "$work"
        if test (count $hits) -gt 0
            for hit in $hits
                plan_row refuse pgo-hit "$archive" "$hit"
            end
            plan_row refuse pgo-instrumented "$archive"
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
        # mutex-timeout is its own failure shape: the BUILDER's queue outlived
        # the wait. It says nothing about the system db.lck or the local db,
        # so no lock/db probe runs on rc 75 (2026-10-04) — and the named line
        # above is what the run record keys `mutex-timeout` off.
        return $rc
    end
    if test "$rc" -ne 0
        # Lock-failure path (install_pkgs_now and -ia funnel through here): a
        # failed pacman commonly means db.lck (2026-09-23: six runs died on
        # "could not lock database: File exists") — REPORT-ONLY since
        # 2026-10-04: the probe names holders and the operator command, and
        # never deletes anything.
        check_pacman_lock (pacman_db_lock_path)
        # The other failure this path actually sees is pacman's misleading
        # "invalid or corrupted package", which is the LOCAL db, not the
        # archive (2026-09-24 vscodium): report the broken entry and its
        # operator repair command right here. Also report-only.
        check_pacman_db_health (pacman_db_local_path)
    end
    return $rc
end

# makepkg's `-s` syncdeps runs pacman THROUGH $PACMAN, OUTSIDE the builder's
# flock (run_pacman in /usr/bin/makepkg: `PACMAN=${PACMAN:-pacman}` ~line
# 1203, resolved as PACMAN_PATH=$(type -P $PACMAN) for both -T probes and -S
# installs — verified 2026-09-23). Six dep-pacmans raced the builder's
# `pacman -U` at 19:33:58 that day. The shim pins the MUTATING calls to the
# SAME mutex run_pacman_locked uses; read-only queries (-Q/-T and -S lookups)
# run unlocked — they take no alpm lock, so queueing them behind a
# transaction only manufactures rc-75 timeouts on a healthy run (2026-10-04).
# No deadlock: run_pacman_locked is a leaf
# (flock → /usr/bin/pacman directly, never re-entering makepkg), so the lock
# order cannot cycle. On flock timeout rc=75 propagates as a loud dep-install
# failure — the accepted outcome.
function ensure_pacman_shim
    if not ensure_state_dirs
        return 1
    end
    set -l shim "$LOG_DIR/.pacman-shim"
    set -l tmp "$shim.tmp.$fish_pid"
    # %d,%d → _PACMAN_MUTEX_WAIT (flock wait + timeout message); the mutex path
    # is baked as a shell-QUOTED literal — GSA_STATE_DIR is user-controlled and
    # an unquoted path word-splits or injects into this build-user script.
    set -l mutex_lit "'"(string replace -a "'" "'\\''" -- "$_PACMAN_MUTEX")"'"
    if not printf '#!/bin/sh\n# build-all.fish: makepkg -s dep installs must share the builder mutex.\n# Transactions queue on the mutex; read-only queries run unlocked (2026-10-04).\nP=/usr/bin/pacman\nq=\nt=\nfor a in "$@"; do\n    case $a in\n        -Q*|-T|-Ss|-Si|-Sg|-Sl|-Sp|--query|--deptest) q=1 ;;\n        -S*|-U*|-R*|-D*|-F*|--sync|--remove|--upgrade|--database|--files) t=1 ;;\n    esac\ndone\nif [ -n "$q" ] && [ -z "$t" ]; then\n    exec "$P" "$@"\nfi\nflock -x -w %d %s "$P" "$@"\nrc=$?\nif [ "$rc" -eq 75 ]; then\n    echo "builder pacman mutex timed out after %d seconds" >&2\nfi\nexit "$rc"\n' \
            "$_PACMAN_MUTEX_WAIT" "$mutex_lit" "$_PACMAN_MUTEX_WAIT" >"$tmp"
        command rm -f -- "$tmp"
        return 1
    end
    if not chmod 755 "$tmp"
        command rm -f -- "$tmp"
        return 1
    end
    # Write-time ownership: publish the shim as the build user (the exec'ing
    # makepkg runs as them; a SIGKILL between here and mv only strands a
    # .tmp file, never a root-owned shim — the next run replaces it by rename).
    if test "$_ROOT_MODE" = "1"; and not chown "$_BUILD_USER": "$tmp" 2>/dev/null
        command rm -f -- "$tmp"
        return 1
    end
    # Atomic replace: a lane already executing the old inode keeps running.
    if not mv -f -- "$tmp" "$shim"
        command rm -f -- "$tmp"
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
    if not command rm -v -- $targets
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
    set -l all_eval_failures

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

        # Sources as makepkg sees them. A recipe that cannot be EVALUATED is
        # named and counted, never folded into "no sources": -ccc must not
        # report a clean scan over recipes it never read (2026-10-05).
        set -l sources (pkgbuild_array_checked "$d" source)
        if test $status -ne 0
            ui_error "$d/PKGBUILD cannot be evaluated — its sources were NOT scanned"
            set -a all_eval_failures "$d/PKGBUILD"
        end
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
        else
            echo "Nothing to delete — all found sources are preserved symlinks."
        end
        report_pkgbuild_eval_failures $all_eval_failures
        return $status
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
        report_pkgbuild_eval_failures $all_eval_failures
        return $status
    end

    for t in $all_targets
        # Safety net: never touch anything outside the workspace
        if string match -q "$SCRIPT_DIR/*" -- "$t"
            if test "$_ROOT_MODE" = "1"
                if not command rm -rf -- "$t"
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
    if not report_pkgbuild_eval_failures $all_eval_failures
        return 1
    end
    ui_success "Nuclear cleanup complete."
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
    set -l eval_failures

    # Collect git sources as "effectiveURL|localName|pkgDir"
    for d in (find_pkg_dirs)
        # A recipe that cannot be EVALUATED is named and counted, never folded
        # into "no sources": -ln must not report a clean scan over recipes it
        # never read (2026-10-05).
        set -l srcs (pkgbuild_array_checked "$d" source)
        if test $status -ne 0
            ui_error "$d/PKGBUILD cannot be evaluated — its sources were NOT scanned"
            set -a eval_failures "$d/PKGBUILD"
        end
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
        report_pkgbuild_eval_failures $eval_failures
        return $status
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
                command rm "$twin_path"
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
            report_pkgbuild_eval_failures $eval_failures
            return $status
        end
        for t in $deletions
            if not command rm -rf -- "$t"
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
    report_pkgbuild_eval_failures $eval_failures
    set -l eval_status $status
    if test "$n_error" -gt 0
        echo "Shared-mirror scan encountered $n_error error(s)."
        return 1
    end
    return $eval_status
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
    # Freshness guard: a same-version rebuild whose archive is NEWER than the
    # install must still be installed — version equality alone would skip it.
    # Nanosecond precision (R-F37): the install date is second-granular, so a
    # second-equality compare used to skip archives makepkg wrote mid-second
    # AFTER the install. find -newermt compares the full mtime timespec
    # against the install instant, and doubt installs: a probe failure keeps
    # the archive in the set.
    set -l newer (find "$archive" -maxdepth 0 -newermt "@$installed_epoch" -print 2>/dev/null)
    if test $status -ne 0
        return 1
    end
    if test -n "$newer"
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
# Plan rows (fields TAB-framed via the plan_row codec below; an archive or
# member path containing a space must survive the round trip to the consumer
# — space-joined rows were re-split at consumption and handed pacman a
# truncated, nonexistent path):
#   install <archive>                   → run pacman -U for it
#   skip <archive> <installed-version>  → exact version, installed fresher
#   refuse empty-list                   → nothing to install (checked mode)
#   noop empty-list                     → nothing to do (force mode: mirrors -ia)
#   refuse plan-failed                  → the plan failed without a reason row
#   refuse partial-set <pkgdir> <missing>...  → see list_split_pkgs
#   refuse discover-failed <pkgdir>     → see list_split_pkgs
#   refuse pgo-*                        → see pgo_payload_refusals
#   refuse abi-*                        → see abi_provide_refusals
# A refusal row aborts the whole transaction; skip and install rows may mix.

# plan_row FIELD... → one framed plan/probe row; plan_row_fields ROW → its
# fields. Tab framing is the codec of the install pipeline: producers and
# consumers meet ONLY through these two, so no field-splitting drift can hand
# pacman a truncated path (R-F22). A field containing a literal tab would
# corrupt the frame; nothing the pipeline names can contain one.
function plan_row
    string join \t -- $argv
end

function plan_row_fields -a row
    string split \t -- "$row"
end

function install_plan -a mode
    set -l archives $argv[2..-1]
    # Discovery damage recorded by list_split_pkgs owns this plan's refusal:
    # the built set of a recipe in the selection is incomplete or could not be
    # established, so installing the remaining archives is the silent shrink
    # the single-transaction entries must never do (R-F25). The rows are
    # consumed ONCE — they name the reason `refuse empty-list` would hide.
    if test (count $_GSA_DISCOVER_REFUSALS) -gt 0
        printf '%s\n' $_GSA_DISCOVER_REFUSALS
        set -g _GSA_DISCOVER_REFUSALS
        return 1
    end
    if test (count $archives) -eq 0
        # An empty list is NOT success on the -i path. It means discovery
        # found no archive for the current evaluated pkgver-pkgrel, or could
        # not establish one; installing nothing leaves later packages
        # compiling against the old system version.
        # tests/install-archive-guard.sh pins both halves.
        if test "$mode" = force
            plan_row noop empty-list
            return 0
        end
        plan_row refuse empty-list
        return 1
    end
    # Never plan a PGO phase-1 payload: libgcov would recreate its build tree
    # on every run, and under -i every later package would build against it.
    set -l pgo_rows (pgo_payload_refusals $archives)
    set -l pgo_failed $status
    if test $pgo_failed -ne 0
        # A PGO refusal already fails the plan and the decision half must
        # stay pacman-free to the very end (tests/pgo-payload-guard.sh and
        # tests/install-conflict-ask.sh C2 pin zero pacman calls on those
        # paths), so the ABI gate below is not even consulted — it is the
        # only other plan-step reader of the installed database.
        printf '%s\n' $pgo_rows
        return 1
    end
    # ABI-drift guard layer 3 (abi_provide_refusals): a bare soname provide
    # that disappears/changes against the installed database while the
    # consumer closure is open refuses the plan — BEFORE the force branch, so
    # -fi/-ia can never route around it. Decision half stays silent.
    set -l abi_rows (abi_provide_refusals $archives)
    if test $status -ne 0
        printf '%s\n' $abi_rows
        return 1
    end
    if test "$mode" = force
        # -fi / -ia: the same-version sanity check is bypassed ENTIRELY —
        # install_skip_reason is never even consulted, so there is no second
        # implementation of the skip decision to drift.
        for archive in $archives
            plan_row install "$archive"
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
            plan_row skip "$archive" "$iver"
        else
            plan_row install "$archive"
        end
    end
    return 0
end

# install_emit SINK LOG_FILE LEVEL TEXT — the ONE rendering seam of the
# install pipeline. quiet: append to the transcript (lane children must never
# write to the terminal — the dispatcher owns all progress rendering). loud:
# print with the usual icon. LEVEL is error, warn or info.
function install_emit -a sink log_file level text
    if test "$sink" = quiet
        switch $level
            case error
                printf '%s %s\n' "$_UI_ICON_ERROR" "$text" >>"$log_file"
            case warn
                printf '%s %s\n' "$_UI_ICON_WARN" "$text" >>"$log_file"
            case '*'
                printf '%s %s\n' "$_UI_ICON_INFO" "$text" >>"$log_file"
        end
    else
        switch $level
            case error
                ui_error "$text"
            case warn
                ui_warning "$text"
            case '*'
                ui_info "$text"
        end
    end
end

# install_register_names ARCHIVE... → the package names each archive installs
# (one per line, deduped), rc 1 the moment an archive is UNNAMEABLE. Two name
# sources per archive, in authority order:
#   1. the archive's own .PKGINFO (pkgbase + pkgname) — what pacman -U will
#      actually install;
#   2. the recipe directory beside the archive (PKGDEST=$startdir is the house
#      layout): the committed .SRCINFO's pkgbase+pkgname, else the evaluated
#      PKGBUILD's pkgbase/pkgname — the same "published claim one level down"
#      expected_output_names falls back to for synthetic workspaces.
# Fixture stub archives are EMPTY on purpose (tests/lib/fixture-lib.bash), so
# rung 2 is what their runs resolve through. Neither rung answering is
# fail-closed by design: skipping registration silently would leave exactly
# the names the transaction installs unprotected, which is the bug class this
# feature exists to close. Diagnostics go to stderr so the caller can route
# them through its own sink (a lane child must never write to the terminal).
function install_register_names
    for archive in $argv
        set -l dir (path dirname -- "$archive")
        set -l names
        for line in (archive_pkginfo "$archive")
            set -l base (string match -r -g '^pkgbase = (.+)$' -- "$line")
            test (count $base) -ge 1; and set -a names $base[1]
            set -l out (string match -r -g '^pkgname = (.+)$' -- "$line")
            test (count $out) -ge 1; and set -a names $out[1]
        end
        if test (count $names) -eq 0
            if test -f "$dir/.SRCINFO"
                set names (srcinfo_pkgnames "$dir/.SRCINFO")
            end
        end
        if test (count $names) -eq 0
            set names (pkgbuild_array_checked "$dir" pkgbase) (pkgbuild_array_checked "$dir" pkgname)
        end
        if test (count $names) -eq 0
            echo "install-register: cannot establish the package names of "(basename -- "$archive")" — no readable .PKGINFO and no pkgbase/pkgname in $dir" >&2
            return 1
        end
        printf '%s\n' $names
    end
    return 0
end

# install_register_ignorepkg LOG_FILE SINK ARCHIVE... — the dynamic IgnorePkg
# registration step of the ONE install pipeline, run BEFORE pacman -U so a
# name is never installed while unprotected (the whole point: the retired
# static closure in /etc/pacman.conf cannot know what a future build installs).
# It registers pkgbase+pkgname of every accepted archive (install AND skip rows
# — both are archives this run keeps), through the shared names-driven core
# register_ignorepkg_names (lib/audit.fish), into $_IGNOREPKG_CONF when set
# (the fixture seam) or /etc/pacman.conf.
# The step runs under the BUILDER's pacman mutex (run_pacman_locked → the
# hidden --install-register seam), with the bounded db.lck deferral INSIDE the
# same critical section: two lanes must never interleave the conf
# read-modify-write, and a mutex timeout must stay the one failure shape it is
# for `pacman -U` (rc 75 → `mutex-timeout`, no recovery probes —
# tests/pacman-mutex-shim.sh pins both). Registration failure, lock timeout or
# mutex timeout REFUSES the install (fail-closed: an unregistered name is the
# bug, not a footnote), and --no-register-ignorepkg (-gx _IGNOREPKG_REGISTER
# 0) skips the step loudly.
function install_register_ignorepkg -a log_file sink
    set -l archives $argv[3..-1]
    if test (count $archives) -eq 0
        return 0
    end
    if set -q _IGNOREPKG_REGISTER; and test "$_IGNOREPKG_REGISTER" = 0
        install_emit "$sink" "$log_file" warn "IgnorePkg registration skipped (--no-register-ignorepkg) — "(count $archives)" archive name(s) were NOT added to the pacman.conf closure"
        return 0
    end
    # Names first: an unnameable archive is refused before anything is waited
    # for or written. stderr rides along in the same capture (it is only ever
    # written on the failure path), so both routes land in the transcript.
    set -l named (install_register_names $archives 2>&1)
    set -l nrc $status
    if test $nrc -ne 0
        for line in $named
            install_emit "$sink" "$log_file" error "$line"
        end
        install_emit "$sink" "$log_file" error "refusing to install: a package name could not be established, so its IgnorePkg registration cannot be guaranteed"
        return 1
    end
    set -l conf /etc/pacman.conf
    if set -q _IGNOREPKG_CONF; and test -n "$_IGNOREPKG_CONF"
        set conf $_IGNOREPKG_CONF
    end
    set -l subject (count $named)" name(s) from "(count $archives)" archive(s)"
    set -l reg_out (run_pacman_locked "$log_file" \
        fish "$SCRIPT_DIR/build-all.fish" --install-register "$conf" "$subject" $named 2>&1)
    set -l rrc $status
    for line in $reg_out
        if string match -q '*warning*' -- "$line"
            install_emit "$sink" "$log_file" warn "$line"
        else if test $rrc -ne 0; or string match -q '*timed out*' -- "$line"
            install_emit "$sink" "$log_file" error "$line"
        else
            install_emit "$sink" "$log_file" info "$line"
        end
    end
    if test $rrc -ne 0
        if test $rrc -eq 75
            install_emit "$sink" "$log_file" error "IgnorePkg registration never ran: the builder pacman mutex timed out — refusing to install unregistered package name(s)"
        else
            install_emit "$sink" "$log_file" error "IgnorePkg registration failed — refusing to install package name(s) the pacman.conf closure does not cover"
        end
        return 1
    end
    return 0
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
    set -l skip_versions
    set -l refusals
    for row in $rows
        set -l fields (plan_row_fields "$row")
        switch $fields[1]
            case install
                set -a installs $fields[2]
            case skip
                set -a skips $fields[2]
                set -a skip_versions $fields[3]
            case noop
                # force mode with nothing to do — no message, no transaction.
            case '*'
                set -a refusals $row
        end
    end
    if test (count $refusals) -gt 0
        for row in $refusals
            set -l fields (plan_row_fields "$row")
            switch $fields[2]
                case empty-list
                    install_emit "$sink" "$log_file" error "install requested but no built package archive matched the current pkgver-pkgrel — refusing to report success"
                case plan-failed
                    install_emit "$sink" "$log_file" error "the install plan failed without a reason row — refusing to install"
                case partial-set
                    install_emit "$sink" "$log_file" error "refusing to install "(basename "$fields[3]")": built output set is incomplete (missing: "(string join ' ' $fields[4..-1])") — rebuild before installing"
                case discover-failed
                    install_emit "$sink" "$log_file" error "refusing to install "(basename "$fields[3]")": archive discovery could not be established (pkgver/pkgrel unusable) — fix the recipe before installing"
                case pgo-temp
                    install_emit "$sink" "$log_file" error "cannot create a temp dir to verify "(basename "$fields[3]")
                case pgo-unreadable
                    install_emit "$sink" "$log_file" error "refusing to install "(basename "$fields[3]")": its payload could not be read (tar rc=$fields[4], $fields[5] files), so PGO instrumentation cannot be ruled out"
                case pgo-hit
                    install_emit "$sink" "$log_file" error (basename "$fields[3]")": profile-instrumented payload — "$fields[4]
                case pgo-instrumented
                    install_emit "$sink" "$log_file" error "refusing to install "(basename "$fields[3]")": a phase-1 PGO binary is packaged, so libgcov would recreate its build tree on every run"
                    install_emit "$sink" "$log_file" error "rebuild the recipe so phase 2 really replaces the profiled flags (docs/build-guide.md: PGO)"
                case abi-soname
                    if test "$fields[7]" = "-"
                        install_emit "$sink" "$log_file" error (basename "$fields[3]")": soname provide "$fields[5]" (installed "$fields[6]") disappears in this build — its consumer closure is not in this transaction"
                    else
                        install_emit "$sink" "$log_file" error (basename "$fields[3]")": soname provide "$fields[5]" moves "$fields[6]" -> "$fields[7]" — its consumer closure is not in this transaction"
                    end
                case abi-consumer
                    install_emit "$sink" "$log_file" error "installed consumer "$fields[4]" is not in this transaction — a moved soname provide would leave it broken (rebuild it in the same batch, or install the built set together with -ia)"
                case '*'
                    install_emit "$sink" "$log_file" error "unrecognized install-plan refusal: $row"
            end
        end
        return 1
    end
    # Dynamic IgnorePkg registration (2026-10-05) runs here — after the
    # refusals, before the transaction: every accepted archive (install AND
    # skip rows) must have its names in the pacman.conf closure before pacman
    # -U can install them. Failure refuses the whole install (fail-closed).
    if not install_register_ignorepkg "$log_file" "$sink" $installs $skips
        return 1
    end
    if test (count $skips) -gt 0
        # D-F14: the note must not present ONE row's version as every skipped
        # package's. One distinct version keeps the original phrasing; a mixed
        # skip set shows the version SET.
        set -l uniq_versions (printf '%s\n' $skip_versions | sort -u)
        if test (count $uniq_versions) -eq 1
            install_emit "$sink" "$log_file" info (count $skips)" of "(math (count $skips) + (count $installs))" package(s) already installed at $uniq_versions[1] — skipping their install"
        else
            install_emit "$sink" "$log_file" info (count $skips)" of "(math (count $skips) + (count $installs))" package(s) already installed at their built versions ("(string join ', ' $uniq_versions)") — skipping their install"
        end
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
    # The installed-database memos (abi_installed_provides / abi_pkg_installed
    # / abi_id_installed) answered from the PRE-transaction state — drop them
    # the moment the transaction has run so every later probe (the NEEDED
    # probe below, the next install's plan) reads the NEW database, not the
    # snapshot the plan consulted.
    abi_installed_cache_clear
    if test $irc -ne 0
        if test "$sink" = quiet
            if test $irc -eq 75
                # mutex-timeout is a queue failure, not a pacman error — name
                # it so the run record can carry `mutex-timeout` instead of
                # folding it into build-failed (2026-10-04).
                printf '%s Install failed: builder pacman mutex timed out (rc=75) — the transaction never ran\n' "$_UI_ICON_ERROR" >>"$log_file"
            else
                printf '%s Install failed (rc=%s) — stopping: later packages would build against the wrong system state\n' "$_UI_ICON_ERROR" "$irc" >>"$log_file"
            end
            printf '  NOTE: with -i the BUILD may still have succeeded (archive exists); install later with -ia or resume with -s -i\n' >>"$log_file"
        else
            if test $irc -eq 75
                ui_error "Install failed: builder pacman mutex timed out (rc=75) — the transaction never ran"
            else
                ui_error "Install failed (rc=$irc)"
            end
        end
        return 1
    end
    # ABI-drift guard layer 4: after the transaction lands, every installed
    # consumer output's DT_NEEDED must resolve within the newly installed +
    # existing provide set. Failure aborts loudly, sonames named — the
    # transaction already landed, so every later package would otherwise
    # compile against an unresolvable system.
    set -l probe_rows (install_needed_probe $installs)
    set -l probe_status $status
    for row in $probe_rows
        set -l fields (plan_row_fields "$row")
        switch $fields[1]
            case probe-needed
                install_emit "$sink" "$log_file" error "post-install NEEDED probe: "$fields[3]" needs "$fields[4]" — unresolved after the transaction"
            case probe-skipped
                # Named, non-fatal by policy (R-F26): the probe could not run
                # at all, so "clean" must never stand for "unprobed".
                install_emit "$sink" "$log_file" warn "post-install NEEDED probe skipped ($fields[2]) — the post-install ABI layer did not run"
        end
    end
    if test $probe_status -eq 1
        install_emit "$sink" "$log_file" error "post-install NEEDED probe: aborting — the transaction landed with outputs whose sonames do not resolve (rebuild the provider in the same batch, or register the name in config/abi-exclusions.conf)"
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
    set -l plan_status $status
    if test $plan_status -ne 0; and test (count $plan) -eq 0
        # F39: a FAILED plan must never render as "nothing to do". Every plan
        # step is contracted to emit a reason row before failing, so this row
        # is the fail-closed backstop when one someday does not.
        set plan (plan_row refuse plan-failed)
    end
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
        # ONE name surface (D-F4): pkgbase + every pkgname output — the same
        # B/N rows the ABI lookups read. A name is
        # resolvable wherever pacman can resolve it, whichever .SRCINFO field
        # carries it, and every lookup (CLI references, abi_package_id_for_
        # pkgname, register_ignorepkg's universe) answers from this one list.
        # Entries are deduped (a pkgbase equal to its output is one name) and
        # first entry wins in _pkgname_owner; the workspace surface carries no
        # cross-recipe collisions (verified across all committed .SRCINFOs).
        for row in (srcinfo_rows B) (srcinfo_rows N)
            set -l parts (string split -m 1 '|' -- "$row")
            set -l entry "$parts[2]|$parts[1]"
            contains -- "$entry" $_PKGNAME_INDEX; or set -a _PKGNAME_INDEX "$entry"
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
# usage dump that follows lists them all. No first-character prefilter: with the
# full option list below, distance <= 2 yields a single candidate for every typo
# measured and a prefilter only cost true positives (`--xanels` -> `--lanes`).
function _suggest_option -a given
    string match -qr '^--' -- "$given"; or return 0
    set -l options --install --forceinstall --clean --skip --skip-built --vcs-skip-tolerance \
        --no-sync --lanes --jobs --intensity \
        --allow-broken-rustc --no-deps --no-register-ignorepkg --dry-run --list --group --help --topology \
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
        $run_as command rm -f -- "$temporary" 2>/dev/null
        ui_error "$package_id: cannot record GCC build identity: $state_file"
        return 1
    end
    return 0
end

# ─── Build a single package ──────────────────────────────────────────────────
# skip_flag is the skip MODE, not a boolean: 0 = no skip, 1 = -s (freshness-
# gated), 2 = --skip-built (built-set claim, freshness analysis off). It rides
# lane_argv's pinned SKIP field unchanged, so every consumer tests it as a
# mode ("not 0" = any skip claim) rather than against the literal 1.
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
    # before makepkg rather than being hidden by that automatic clean. The
    # decision is the same one the skip block makes (freshness_skip_decision);
    # here only its deferral outcome is acted on — a skip verdict still falls
    # through to the drift clean and rebuild below.
    if test "$toolchain_mismatch" = "1"; and test "$clean_flag" != "1"; and test "$skip_flag" != "0"
        freshness_skip_decision "$pkg_path" "$package_id" "$skip_flag"
        if test "$_FRESHNESS_VERDICT" = "defer"
            return $lane_outcome_defer
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
    #
    # The version check runs BEFORE the skip decision (2026-10-05): freshness
    # is not purely local mtime — a resumed -s run must see upstream movement,
    # or it reports "already built" forever at a stale version. A rewrite bumps
    # the PKGBUILD past every existing archive, so the skip gate then says
    # build on its own.
    set -l sources_before (pkgbuild_array_checked "$pkg_path" source)
    set -l sources_before_status $status
    set -l external_sync 0
    set -l skip_allowed 1
    if test $sources_before_status -eq 2
        # An unevaluable recipe must never be claimed fresh: -s would skip it
        # forever at whatever version the tree happens to hold.
        ui_warning "$package_id: cannot evaluate the PKGBUILD source array — freshness is unverifiable; this run will not skip"
        set skip_allowed 0
    end
    if test "$no_sync_flag" != "1"
        set -l version_provider (package_version_sync_provider "$package_id")
        if test "$version_provider" = nvchecker
            # Source changes and checksum anchoring are handled by the
            # opted-in provider path as one rollback boundary.
            sync_nvchecker_version "$package_id" "$pkg_path"
            set -l sync_status $status
            switch $sync_status
                case 0
                    ;
                case 1 3
                    set skip_allowed 0
                case $lane_outcome_defer
                    return $lane_outcome_defer
                case '*'
                    ui_error "failed to synchronize upstream metadata for $pkg_name"
                    return 1
            end
            set external_sync 1
        else
            sync_stable_version "$pkg_path"
            set -l sync_status $status
            switch $sync_status
                case 0
                    ;
                case 1 3
                    # 1 = pkgver moved, 3 = only pkgrel/epoch moved; the source
                    # diff below decides whether the sums need re-anchoring.
                    set skip_allowed 0
                case 4
                    # The repo query FAILED (unsynced db, mirror error) — the
                    # committed version's freshness is UNVERIFIED. Never a
                    # silent skip and never a silent stale build (2026-10-05):
                    # park the recipe when its consumer chain can absorb the
                    # wait, else build the committed version loudly.
                    set skip_allowed 0
                    switch (unverifiable_defer_plan "$package_id")
                        case defer
                            set -g _DEFER_REASON upstream-unverified
                            ui_error "$pkg_name: the Arch repository version could not be queried — consumer chain can absorb the wait — parking this recipe (deferred)"
                            echo "  Nothing was built or installed; dependents wait (waits-on-deferred)."
                            return $lane_outcome_defer
                        case '*'
                            ui_error "$pkg_name: the Arch repository version could not be queried — building the committed version as-is (its freshness is unverified)"
                    end
                case '*'
                    ui_error "failed to synchronize stable metadata for $pkg_name"
                    return 1
            end
        end
    end
    set -l sources_after (pkgbuild_array_checked "$pkg_path" source)
    set -l sources_after_status $status
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
    if test $sources_after_status -eq 2
        ui_warning "$package_id: cannot evaluate the rewritten PKGBUILD source array — freshness is unverifiable; this run will not skip"
        set skip_allowed 0
    end
    set -l stale_sums 0
    if test (count $moved_sources) -gt 0
        # A moved source is never freshness-skippable either.
        set skip_allowed 0
        if test $external_sync -eq 0
            set stale_sums 1
        end
    end

    # Skip if already built (only when a skip mode is set). The decision — the
    # COMPLETE current-version set, payload-valid, and in -s mode newer than
    # the PKGBUILD, VCS-current or waived — is freshness_skip_decision, shared
    # with the toolchain pre-check above; only the skip CLAIM renders it. The
    # claim is made only when the version check above established there was
    # nothing to do (skip_allowed): over an UNCHECKED repo version "already
    # built" would be a freshness claim this run never made (2026-10-05).
    if test "$skip_flag" != "0"; and test $skip_allowed -eq 1
        freshness_skip_decision "$pkg_path" "$package_id" "$skip_flag"
        switch $_FRESHNESS_VERDICT
            case defer
                return $lane_outcome_defer
            case skip
                if test (count $_FRESHNESS_WAIVER) -gt 0
                    # LOUD on purpose (never lower verification silently):
                    # this skip is a freshness WAIVER, not an untouched
                    # archive, and the named line(s) — unguarded, so they
                    # land in the per-package log in lane mode too — say
                    # exactly what was waived. The run record row carries
                    # the claim as its reason (freshness-waived /
                    # abi-provider-waived / skip-built).
                    for waiver_line in $_FRESHNESS_WAIVER
                        ui_info "$waiver_line"
                    end
                end
                if test "$_BUILD_QUIET" != "1"
                    ui_info "$pkg_name: already built ("(string join ', ' (basename -- $_FRESHNESS_ARCHIVE))")"
                end
                # -s + -i: the skip path installs too — topo order must
                # hold for already-built packages just the same.
                # ($log_file isn't defined yet — use the canonical path.)
                if test "$install_flag" = "1"
                    install_pkgs_now (package_log_file "$package_id") 1 $force_install_flag (list_split_pkgs "$pkg_path"); or return 1
                end
                return 0
        end
    end

    # A waiver only ever describes a SKIP. Every path that reaches this point
    # actually builds — including one whose freshness probe waived an earlier
    # source before a later one moved past tolerance, and the toolchain
    # pre-check's probe before a drift clean — so drop the waiver here or the
    # built package's ok row would claim a skip that never happened.
    set -g _FRESHNESS_WAIVER
    set -g _FRESHNESS_WAIVER_REASON ""

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
            case 5
                # The anchor failure could not roll its own rewrite back: the
                # recipe is left dirty. Nothing may build over it and nothing
                # may quietly park it — stop like an integrity signal, and the
                # anchor's own message named the dirty recipe.
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
                and not command rm -f -- "$after_fields[1].gsa-vcs-revisions"
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
    # Keyed lookup (see _topo_key): the old loop split every _DEPS row until
    # the id matched — O(P) command substitutions per call, paid by every
    # readiness check. Same output contract: the record's deps in record
    # order, one per line; nothing for a no-edge record or unknown id.
    set -l dep_var _TDEP_(_topo_key "$pkg")
    if set -q $dep_var
        set -l deps $$dep_var
        if test (count $deps) -gt 0
            printf '%s\n' $deps
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
    set -l tags_var _TTAGS_(_topo_key "$pkg")
    if set -q $tags_var
        set -l tags (string split ',' -- "$$tags_var")
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
    set -l tags_var _TTAGS_(_topo_key "$pkg")
    if set -q $tags_var
        for tag in (string split ',' -- "$$tags_var")
            if test "$tag" = version-sync=nvchecker
                echo nvchecker
                return
            end
        end
    end
    echo none
end

# package_app_cluster PKG → the record's app-cluster=<name> value, or nothing.
# Members sharing one name belong to one prompt row; the loader caps a record
# at one such tag, and only prompt_app_selection consumes this.
function package_app_cluster -a pkg
    set -l tags_var _TTAGS_(_topo_key "$pkg")
    if set -q $tags_var
        for tag in (string split ',' -- "$$tags_var")
            if string match -q 'app-cluster=*' -- "$tag"
                string replace 'app-cluster=' '' -- "$tag"
                return
            end
        end
    end
end

# has_abi_tagged_dependency PKG → 0 when any transitive dependency carries an
# abi tag. Such a package is a batch MEMBER (its rebuild is obligated by its
# anchor), never an anchor — which is why a leaf `--no-deps qt6-svg` or
# `--no-deps rust-git` is never gated, while llvm-git/qt*-base-git (untagged
# ancestors) are. The graph is acyclic (the loader's topo check proved it),
# so the recursion terminates.
function has_abi_tagged_dependency -a pkg
    # Iterative forward BFS over the keyed dep adjacency (_TDEPKEYS_, built by
    # read_topology_config), with O(1) tag reads (_TTAGS_). The old recursion
    # re-derived deps through command substitutions and scanned _TAGS linearly
    # per node — O(V·E·T) across the gate's per-anchor calls.
    set -l start_key (_topo_key "$pkg")
    set -l queue_keys
    set -l deps_var _TDEPKEYS_$start_key
    if set -q $deps_var
        set queue_keys $$deps_var
    end
    set -l qhead 1
    while test $qhead -le (count $queue_keys)
        set -l key $queue_keys[$qhead]
        set qhead (math $qhead + 1)
        set -l seen_var _ABITAGSEEN_$key
        set -q $seen_var; and continue
        set -f $seen_var 1
        set -l tags_var _TTAGS_$key
        if set -q $tags_var
            set -l tags (string split ',' -- "$$tags_var")
            if contains abi=must $tags; or contains abi=should $tags
                return 0
            end
        end
        set -l next_var _TDEPKEYS_$key
        if set -q $next_var
            set -a queue_keys $$next_var
        end
    end
    return 1
end

# abi_depends_on PKG TARGET → 0 when PKG transitively depends on TARGET.
function abi_depends_on -a pkg target
    set -l target_key (_topo_key "$target")
    set -l start_key (_topo_key "$pkg")
    set -l queue_keys
    set -l deps_var _TDEPKEYS_$start_key
    if set -q $deps_var
        set queue_keys $$deps_var
    end
    set -l qhead 1
    while test $qhead -le (count $queue_keys)
        set -l key $queue_keys[$qhead]
        set qhead (math $qhead + 1)
        test "$key" = "$target_key"; and return 0
        set -l seen_var _ABIDEPSEEN_$key
        set -q $seen_var; and continue
        set -f $seen_var 1
        set -l next_var _TDEPKEYS_$key
        if set -q $next_var
            set -a queue_keys $$next_var
        end
    end
    return 1
end

# abi_batch_dependents ANCHOR → every abi-tagged package that transitively
# depends on ANCHOR (the reverse closure the edge file cannot express), one
# per line, in map order.
function abi_batch_dependents -a anchor
    # Reverse BFS over the keyed consumer adjacency (_TCONSKEYS_) — one pass
    # per anchor instead of a reachability query per (anchor × package) pair
    # (the old `for candidate in $_PACKAGE_IDS: abi_depends_on` was O(V·E) per
    # anchor, minutes at 653 records). The map-order output contract is kept
    # by scanning $_PACKAGE_IDS once against the BFS marks.
    set -l anchor_key (_topo_key "$anchor")
    set -l queue_keys $anchor_key
    set -l qhead 1
    while test $qhead -le (count $queue_keys)
        set -l key $queue_keys[$qhead]
        set qhead (math $qhead + 1)
        set -l seen_var _ABIREVSEEN_$key
        set -q $seen_var; and continue
        set -f $seen_var 1
        set -l cons_var _TCONSKEYS_$key
        if set -q $cons_var
            set -a queue_keys $$cons_var
        end
    end
    for candidate in $_PACKAGE_IDS
        test "$candidate" = "$anchor"; and continue
        test (package_abi_severity $candidate) = none; and continue
        set -l cand_var _ABIREVSEEN_(_topo_key "$candidate")
        set -q $cand_var; and echo $candidate
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

# One "holder pid=N cmd=..." line per process holding the lock INODE open,
# plus at most one "holder unknown: ..." line when idleness cannot be
# proven. Empty output = proven idle; ANY output line = treat as
# busy/unproven and NEVER touch the lock.
# The proof is open-handle inspection of /proc/*/fd against the lock's
# dev+inode (find -samefile; alpm holds db.lck open for a whole transaction,
# verified 2026-10-04), never a process-NAME list: the old
# `pgrep -x pacman|packagekitd|pamac` missed every other alpm client (this
# host runs paru), and probe children killed by a Ctrl-C storm returned a
# confidently EMPTY list that gated deletion of live state.
function pacman_lock_holder_lines -a lock_path
    if test -z "$lock_path"
        echo "  holder unknown: no lock path to inspect — cannot prove the lock idle"
        return 0
    end
    if not test -e "$lock_path"
        # No lock file at all: every alpm transaction holds the lock inode
        # open for its whole duration (verified 2026-10-04), so an absent
        # lock proves no transaction is live. (A lock deleted WHILE held
        # leaves its inode open but unreferenced — unobservable by path, and
        # nothing here acts on the classification anyway.)
        return 0
    end
    if not test -d /proc
        echo "  holder unknown: no /proc to inspect open handles — cannot prove the lock idle"
        return 0
    end
    # Each scan stage's trailing sentinel line carries the child's exit
    # status, so a killed or truncated probe is detected as UNKNOWN instead
    # of silently looking idle — the scan children sit in the foreground pgrp
    # and die on a second SIGINT mid-scan (2026-09-23 teardown storm).
    set -l fd_dirs (LC_ALL=C find /proc -mindepth 2 -maxdepth 2 -type d -name fd -printf '%p\n' 2>/dev/null; echo "__gsa_fd_dirs_end__ $status")
    if test (count $fd_dirs) -eq 0; or not string match -q '__gsa_fd_dirs_end__ *' -- "$fd_dirs[-1]"
        echo "  holder unknown: the open-handle scan was cut short — cannot prove the lock idle"
        return 0
    end
    set -l list_rc (string replace '__gsa_fd_dirs_end__ ' '' -- "$fd_dirs[-1]")
    set -e fd_dirs[-1]
    if test "$list_rc" -ge 128; or test "$list_rc" -eq 127
        echo "  holder unknown: the open-handle scan died (rc=$list_rc) — cannot prove the lock idle"
        return 0
    end
    if not contains -- /proc/1/fd $fd_dirs
        # hidepid (or equivalent) hides other users' processes from readdir:
        # their holders would be invisible, which is unknown, never idle.
        echo "  holder unknown: /proc is restricted for "(id -un)" — cannot prove the lock idle"
        return 0
    end
    # Stage 2 matches the lock inode among those handles. stdout and stderr
    # are captured together: an unreadable fd dir ("Permission denied") means
    # a holder could hide there.
    set -l scan (LC_ALL=C find -L $fd_dirs -maxdepth 1 -samefile "$lock_path" -printf '%p\n' 2>&1; echo "__gsa_lock_scan_end__ $status")
    if test (count $scan) -eq 0; or not string match -q '__gsa_lock_scan_end__ *' -- "$scan[-1]"
        echo "  holder unknown: the open-handle scan was cut short — cannot prove the lock idle"
        return 0
    end
    set -l scan_rc (string replace '__gsa_lock_scan_end__ ' '' -- "$scan[-1]")
    set -e scan[-1]
    if test "$scan_rc" -ge 128; or test "$scan_rc" -eq 127
        echo "  holder unknown: the open-handle scan died (rc=$scan_rc) — cannot prove the lock idle"
        return 0
    end
    set -l holder_pids
    set -l blind 0
    for line in $scan
        if string match -qr '^/proc/[0-9]+/fd/[0-9]+$' -- "$line"
            set -l pid (string replace -r '^/proc/([0-9]+)/fd/.*$' '$1' -- "$line")
            contains -- "$pid" $holder_pids; or set -a holder_pids $pid
        else if string match -q '*Permission denied*' -- "$line"
            set blind 1
        end
    end
    for pid in $holder_pids
        set -l cmd (ps -o args= -p "$pid" 2>/dev/null | string trim)
        test -n "$cmd"; or set cmd "(cmdline unavailable)"
        printf '  holder pid=%s cmd=%s\n' "$pid" "$cmd"
    end
    if test $blind -eq 1
        echo "  holder unknown: some processes hide their open files from "(id -un)" — cannot prove the lock idle"
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

# check_pacman_lock <path> — REPORT-ONLY (contract 2026-10-04): a system
# pacman database lock is NEVER deleted automatically. The 2026-09-23
# "two quiet probes 1 s apart → rm" behaviour lost to three failure modes:
# alpm clients outside the old name list (this host runs paru), the
# probe↔rm TOCTOU window, and a Ctrl-C storm killing the probe children so
# an empty holder list gated `rm` on LIVE pacman state mid-transaction.
# Removal is therefore always an explicit operator action (the named
# `sudo rm` line in pacman_lock_busy_report); this probe only classifies
# the lock — held / stale / unknown — against the lock inode's open handles.
# rc 0 = lock absent (clear to install); rc 1 = lock present (held, stale,
# or unprovable). Nothing is ever removed here.
function check_pacman_lock -a lock_path
    if test -z "$lock_path"; or not test -e "$lock_path"
        return 0
    end
    set -l holders (pacman_lock_holder_lines "$lock_path")
    pacman_lock_busy_report "$lock_path" $holders
    set -l classified idle
    for line in $holders
        if string match -q '  holder pid=*' -- "$line"
            set classified held
            break
        else if string match -q '  holder unknown:*' -- "$line"
            set classified unknown
        end
    end
    switch $classified
        case held
            echo "  status: HELD — a live transaction holds the lock inode open."
        case unknown
            echo "  status: UNKNOWN — idleness could not be proven (see above)."
        case '*'
            echo "  status: STALE — no open handle on the lock inode (proven idle)."
    end
    echo "  NEVER deleted automatically — the Recovery command above is the operator action."
    return 1
end

# pacman_lock_wait_clear PATH — the bounded wait the dynamic IgnorePkg
# registration runs before it rewrites pacman.conf: report the lock state ONCE
# through check_pacman_lock, then poll `test -e` every second until the lock
# file disappears or _PACMAN_LOCK_WAIT_S elapses (default 300; the variable is
# the fixture seam for the timeout case — there is no GSA_* knob).
# rc 0 = the lock is gone (or was never there); 1 = still present at the
# deadline. CONTRACT (2026-10-04, unchanged): the lock is NEVER deleted here —
# this only waits for whoever holds it to finish. Status lines go to stdout so
# the caller renders them through its own sink.
function pacman_lock_wait_clear -a lock_path
    set -l wait_s 300
    if set -q _PACMAN_LOCK_WAIT_S
        if string match -qr '^[0-9]+$' -- "$_PACMAN_LOCK_WAIT_S"
            set wait_s $_PACMAN_LOCK_WAIT_S
        else
            echo "  _PACMAN_LOCK_WAIT_S='$_PACMAN_LOCK_WAIT_S' is not a whole number of seconds — using the default 300"
        end
    end
    if check_pacman_lock "$lock_path"
        return 0
    end
    echo "  waiting up to $wait_s s for the pacman database lock to clear (never removed automatically)"
    set -l waited 0
    while test $waited -lt $wait_s
        sleep 1
        set waited (math $waited + 1)
        if not test -e "$lock_path"
            echo "  pacman database lock cleared after $waited s"
            return 0
        end
    end
    echo "  pacman database lock still present after $waited s — giving up (nothing was removed)"
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
    echo "  A live transaction may be committing these right now — do not touch"
    echo "  them while it runs. The builder NEVER deletes local database entries"
    echo "  automatically; once nothing is running, repair by hand:"
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
# Rules mirror check_pacman_lock (2026-10-04): REPORT-ONLY. The entries are
# named with the exact operator repair command and NEVER deleted here — the
# idle-removal gate inherited the same three failure modes as the lock
# (name-list gap, probe↔rm TOCTOU, Ctrl-C-killed probes deleting live state
# mid-commit), so repair is an explicit operator action.
# rc 0 = nothing broken; rc 1 = broken entries present (reported, never
# touched).
function check_pacman_db_health -a local_dir
    if test -z "$local_dir"; or not test -d "$local_dir"
        return 0
    end
    set -l broken (pacman_db_broken_entries "$local_dir")
    if test (count $broken) -eq 0
        return 0
    end
    # A live alpm transaction holds <dbpath>/db.lck open for its whole
    # duration, and these entries live in <dbpath>/local — the sibling lock
    # is the right inode to ask about.
    set -l lock_path (path dirname "$local_dir")/db.lck
    set -l holders (pacman_lock_holder_lines "$lock_path")
    ui_warning "local package database has "(count $broken)" broken entry(ies) — report-only, never repaired automatically:"
    pacman_db_broken_report "$local_dir" $holders
    set -l classified idle
    for line in $holders
        if string match -q '  holder pid=*' -- "$line"
            set classified held
            break
        else if string match -q '  holder unknown:*' -- "$line"
            set classified unknown
        end
    end
    switch $classified
        case held
            echo "  status: HELD — a live transaction may be committing these entries."
        case unknown
            echo "  status: UNKNOWN — idleness could not be proven (see above)."
        case '*'
            echo "  status: IDLE — no open handle on $lock_path."
    end
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
        # pgo_payload_refusals unrolls the archive to inspect its payload;
        # readelf arms the post-install NEEDED probe (R-F26: gate up front,
        # the probe's own skip stays a named non-fatal backstop).
        set -a required tar strings readelf
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

# The topology id charset: ONE pattern, the loader's own rule (its id check
# matches against THIS — read_topology_config refuses anything else at config
# load), asserted again at the wire's PRODUCER so a drifted identity can
# never reach the wire and degrade a good build to `lost (125)` at the reap
# (R-F29). Defined once here, referenced by loader and codec alike.
set -g _TOPOLOGY_ID_RE '^[A-Za-z0-9._+-]+$'

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
# an empty pkg (identity is mandatory), a pkg outside the loader's id charset
# (_TOPOLOGY_ID_RE), a non-numeric rc/dur (the outcome vocabulary is numeric by
# construction), or a malformed reason token.
function lane_result_encode -a pkg rc dur reason
    if test -z "$pkg"
        return 1
    end
    if not string match -qr "$_TOPOLOGY_ID_RE" -- "$pkg"
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
# which splits on newlines only. rc 1 = no valid line (shape or numeric
# mismatch); rc 2 = FOREIGN: a well-formed line carrying a different identity
# — another run's or an orphan's result that landed here. A foreign line is
# NEVER this lane's outcome: the reap must ignore it, not classify it and not
# kill the lane that owns the slot (R-F9). Callers treat any failure as "no
# valid result".
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
        return 2
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
        command rm -f -- "$tmp_result"
        return 1
    end
    # Write-time ownership: in root mode the lane child creates this tmp as
    # root, so hand it to the build user BEFORE the atomic publish — the
    # published result must never be root-owned. A SIGKILL between printf and
    # chown strands only the tmp; the next run's startup sweep collects it
    # (sweep_stale_run_artifacts — the "next run rm -f's" never used to happen).
    if test "$_ROOT_MODE" = "1"; and not chown "$_BUILD_USER": "$tmp_result" 2>/dev/null
        command rm -f -- "$tmp_result"
        return 1
    end
    if not mv -f -- "$tmp_result" "$result_file"
        command rm -f -- "$tmp_result"
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
    set -l active_pkgs $_ACTIVE_LANE_PKGS
    # The globals stay populated until the END: a second signal arriving
    # during the grace window escalates through kill_active_lanes_immediate,
    # which reads _ACTIVE_LANE_PIDS — clearing early would make the escalation
    # a no-op exactly when it matters.
    # Fleet-wide teardown in THREE phases, not one stop_lane_process per lane
    # in series: a serial TERM→grace→KILL cost ~3 min for six lanes and was
    # un-abortable while it ran (R-F15). One TERM per pid, ONE shared grace
    # window, ONE SIGKILL sweep. The per-pid TERM discipline of
    # stop_lane_process is preserved exactly: the 2026-09-23 blitz re-TERMed
    # a running `pacman -U` mid db.lck unlock — each pid is TERMed ONCE and a
    # transaction that survived the TERM gets the whole grace to finish.
    for i in (seq (count $active_pids))
        set -l lane_pid "$active_pids[$i]"
        set -l pkg ''
        if test $i -le (count $active_pkgs)
            set pkg "$active_pkgs[$i]"
        end
        set -l pkg_label '-'
        test -n "$pkg"; and set pkg_label "$pkg"
        set -l lane_process_ids (lane_processes "$lane_pid")
        set -l pid_list '-'
        if test (count $lane_process_ids) -gt 0
            set pid_list (string join ',' -- $lane_process_ids)
        end
        dispatcher_log "stop begin reason=interrupt pgid=$lane_pid pkg=$pkg_label pids=$pid_list"
        for process_id in $lane_process_ids
            kill -TERM "$process_id" 2>/dev/null
        end
    end
    # Shared grace (wall-clock deadline, see stop_lane_process): every lane's
    # stragglers drain inside ONE window instead of one window each.
    set -l grace_deadline (math (date +%s) + $_LANE_STOP_GRACE_S)
    while true
        set -l survivors 0
        for lane_pid in $active_pids
            if test (count (lane_processes "$lane_pid")) -gt 0
                set survivors (math $survivors + 1)
            end
        end
        test $survivors -eq 0; and break
        if test (date +%s) -ge $grace_deadline
            break
        end
        sleep 0.1
    end
    for i in (seq (count $active_pids))
        set -l lane_pid "$active_pids[$i]"
        set -l pkg ''
        if test $i -le (count $active_pkgs)
            set pkg "$active_pkgs[$i]"
        end
        set -l pkg_label '-'
        test -n "$pkg"; and set pkg_label "$pkg"
        set -l lane_process_ids (lane_processes "$lane_pid")
        for process_id in $lane_process_ids
            # Escalation is exceptional and must be auditable in BOTH logs.
            dispatcher_log "escalate: pid=$process_id pgid=$lane_pid pkg=$pkg_label SIGKILL after grace reason=interrupt"
            if test -n "$pkg"
                set -l pkg_log (package_log_file "$pkg")
                if ensure_log_writable "$pkg_log"
                    printf '%s [DEBUG-gsa-term] escalate: pid=%s SIGKILL after %ss grace (reason=%s)\n' \
                        "$_UI_ICON_WARN" "$process_id" "$_LANE_STOP_GRACE_S" interrupt >>"$pkg_log"
                end
            end
            kill -KILL "$process_id" 2>/dev/null
        end
        if test (count $lane_process_ids) -gt 0
            for poll in (seq 20)
                set lane_process_ids (lane_processes "$lane_pid")
                test (count $lane_process_ids) -eq 0; and break
                sleep 0.1
            end
        end
        wait "$lane_pid" 2>/dev/null
    end
    # Only THIS run's result files: a foreign run's leftovers are never ours
    # to delete (the startup sweep — which owns the whole directory because
    # the run lock proves no live run exists — collects those).
    find "$LOG_DIR" -maxdepth 1 -name ".lane.$_RUN_ID.*.result" -delete 2>/dev/null
    set -g _ACTIVE_LANE_PIDS
    set -g _ACTIVE_LANE_PKGS
    dispatcher_log "cleanup done"
end

# ─── Run identity: one run per workspace (R-F9) ─────────────────────────────
# The workspace run lock is held for the whole run by a tiny HOLDER process
# (flock(1) on $_STATE_DIR/run.lock) that outlives the dispatcher by at most
# one 0.25 s poll: the flock dies with the holder and the holder dies with the
# dispatcher, so a crashed run can never block the next one. A second run is
# REFUSED, never queued — this repo builds one workspace at a time, and the
# refusal NAMES the holder. Held before any dispatch, which also makes every
# stale result/tmp artifact in $_STATE_DIR provably ownerless: the sweeps
# below may delete wholesale.

function run_lock_acquire
    set -g _RUN_LOCK_HOLDER ""
    set -l lock_file "$_STATE_DIR/run.lock"
    set -l stamp "pid $fish_pid started "(date '+%Y-%m-%dT%H:%M:%S%z')
    # ONE process holds the lock: the watcher itself locks fd 9 (the flock
    # fd idiom — the lock lives on the open file description) instead of
    # flock's command mode, which left an orphaned `sh -c` poll loop when
    # release killed only the flock parent: the orphan then lingered up to
    # one 0.25 s poll past its dispatcher and a leak scan could catch it.
    # The stamp is written only after acquisition — the acquire signal; a
    # holder that exits at once was refused. The holder watches the
    # dispatcher pid and exits when it vanishes (SIGKILL cannot strand the
    # lock). `9<>` never truncates: a refused run must leave the holder's
    # stamp readable for the refusal UX.
    sh -c 'exec 9<>"$2" || exit 1
flock -n 9 || exit 1
printf "%s\n" "$1" >"$2"
while kill -0 "$3" 2>/dev/null; do sleep 0.25; done' \
        sh "$stamp" "$lock_file" "$fish_pid" 2>/dev/null &
    set -g _RUN_LOCK_HOLDER $last_pid
    for poll in (seq 40)
        if grep -qF "$stamp" "$lock_file" 2>/dev/null
            return 0
        end
        if not lane_pid_alive "$_RUN_LOCK_HOLDER"
            break
        end
        sleep 0.05
    end
    if grep -qF "$stamp" "$lock_file" 2>/dev/null
        return 0
    end
    set -l holder_line (head -n 1 -- "$lock_file" 2>/dev/null | string trim)
    if not lane_pid_alive "$_RUN_LOCK_HOLDER"; and test -z "$holder_line"
        # The helper died BEFORE recording a holder and no foreign holder is
        # registered: that is a broken lock mechanism (e.g. no flock), never
        # "another build is running" — say so. (A contended lock also kills
        # the helper at `flock -n`, but then a holder stamp exists above.)
        set -g _RUN_LOCK_HOLDER ""
        ui_error "cannot establish the run lock — the lock helper exited before recording a holder"
        echo "  lock: $lock_file"
        echo "  Is flock(1) available and functional? Nothing was started."
        return 1
    end
    test -n "$holder_line"; or set holder_line "(holder unknown)"
    ui_error "another build already holds this workspace's run lock — refusing to run concurrently"
    echo "  lock: $lock_file"
    echo "  holder: $holder_line"
    echo "  Nothing is queued: this repo runs one build per workspace at a time. The"
    echo "  holder releases the lock by itself when its run ends or dies — if the"
    echo "  holder pid is gone, just rerun."
    wait "$_RUN_LOCK_HOLDER" 2>/dev/null
    set -g _RUN_LOCK_HOLDER ""
    return 1
end

function run_lock_release
    if test -n "$_RUN_LOCK_HOLDER"
        # $_RUN_LOCK_HOLDER IS the lock-holding process (see run_lock_acquire):
        # killing it releases the lock and the poll loop in one step.
        command kill "$_RUN_LOCK_HOLDER" 2>/dev/null
        wait "$_RUN_LOCK_HOLDER" 2>/dev/null
        set -g _RUN_LOCK_HOLDER ""
    end
end

# orphan_lane_sweep — detect and stop lanes of a PREVIOUS run (R-F8). A lane's
# argv carries its run-scoped result path, so any live `--lane-job` referencing
# THIS workspace's log dir belongs to a dead run: we hold the run lock, so no
# living dispatcher can own it. Left alone they keep building AND installing
# (`sudo pacman -U`) unattended and overlap this run (the OOM hazard).
function orphan_lane_sweep
    set -l log_prefix "$LOG_DIR/"
    set -l log_pattern (string escape --style=regex -- "$log_prefix")
    set -l orphans
    for row in (ps -eo pid=,args= 2>/dev/null)
        set -l fields (string trim -- "$row" | string split -m 2 ' ')
        test (count $fields) -ge 3; or continue
        set -l pid $fields[1]
        set -l cmdline (string join ' ' -- $fields[2..-1])
        test "$pid" != "$fish_pid"; or continue
        string match -q '*--lane-job*' -- "$cmdline"; or continue
        string match -qr -- "$log_pattern" "$cmdline"; or continue
        set -a orphans $pid
    end
    if test (count $orphans) -eq 0
        return 0
    end
    for pid in $orphans
        ui_warning "stopping an orphaned lane of a previous run: pid $pid"
        dispatcher_log "orphan lane: pid=$pid of a previous run — stopping (no live dispatcher owns it)"
        stop_lane_process "$pid" orphan ""
    end
end

# sweep_stale_run_artifacts — crash leftovers of dead runs (R-F34):
# `*.tmp.$pid` writers (write_lane_result, the pacman shim, toolchain records)
# and `*.gsa-vcs-revisions.tmp.XXXXXX` manifests. The run lock proves nothing
# alive owns them. Unremovable leftovers (root-owned from a killed root run,
# swept unprivileged) are NAMED with their operator command, never silenced.
function sweep_stale_run_artifacts
    set -l stale (find "$_STATE_DIR" -type f \
        \( -name '*.tmp.*' -o -name '.lane*.result' \) -printf '%p\n' 2>/dev/null)
    # Manifest temps sit beside built archives at RECIPE depth — which is
    # packages/<cat>/<pkg>/ here but packages/<id>/ in fixture workspaces — so
    # match by name anywhere below packages/, never at a fixed depth.
    set -a stale (find "$SCRIPT_DIR/packages" -type f \
        -name '*.gsa-vcs-revisions.tmp.*' \
        -not -path '*/src/*' -not -path '*/pkg/*' -not -path '*/build/*' \
        -printf '%p\n' 2>/dev/null)
    for path in $stale
        # `command rm`: this host defines a fish `rm` FUNCTION that moves
        # targets to a Trash instead of deleting them — a trash-move leaves
        # the artifact unowned-but-present semantics wrong (and fails
        # differently). The external rm is the only real deletion.
        if command rm -f -- "$path" 2>/dev/null; and not test -e "$path"
            continue
        end
        ui_warning "cannot remove stale runtime artifact (owner "(stat -c %U -- "$path" 2>/dev/null)"): $path"
        printf '    or: sudo rm -f %s\n' "$path" >&2
    end
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
    if not command rm -f -- "$probe.rs" "$probe.bin"
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

# dispatch_state_refresh — maintain the O(1) per-name markers that
# pick_next_ready's non-force scan reads. The lane state lists are append-only
# during a run (_lane_sorted is replaced once at run start and only appended
# by force_queue_packages afterwards), so a full rebuild keys off the sorted
# count and everything else is tail-sync: each list's new tail entries are
# marked once. Markers are per NAME (keyed via _topo_key, injective) — exactly
# what `contains "$pkg" $_lane_...` matched on, so a duplicated name in
# _lane_sorted keeps one shared state.
function dispatch_state_refresh
    set -l n (count $_lane_sorted)
    if test "$n" != "$_DS_N"
        # Stale-key hygiene for the keyed globals: names pattern-swept, never
        # tracked in a growing list (see read_topology_config).
        set -l stale (set -n | string match -r '^_(?:DS_DEPKEYS|DS_STARTED|DS_DONE|DS_DEFER|DS_CORE|DS_BAND|DS_INLIST)_.*$')
        if test (count $stale) -gt 0
            set -e $stale
        end
        set -g _DS_N $n
        set -g _DS_KEYS (_topo_key $_lane_sorted)
        set -g _DS_SLOT_IDX (seq $n)
        set -g _DS_OFF_STARTED 1
        set -g _DS_OFF_DONE 1
        set -g _DS_OFF_DEFER 1
        for key in $_DS_KEYS
            set -g _DS_INLIST_$key 1
        end
        # Core and build-tools membership markers (static per run) — the
        # band-first and core-solo tests in the scan.
        for key in (_topo_key $_GROUP_core)
            set -g _DS_CORE_$key 1
        end
        for key in (_topo_key $_GROUP_build_tools)
            set -g _DS_BAND_$key 1
        end
        # In-list dep keys per name: deps_of's contract minus the external
        # deps the readiness check skips, precomputed once.
        for key in $_DS_KEYS
            set -l tdeps_var _TDEPKEYS_$key
            set -l in_list
            for dep_key in $$tdeps_var
                if set -q _DS_INLIST_$dep_key
                    set -a in_list $dep_key
                end
            end
            set -g _DS_DEPKEYS_$key $in_list
        end
    end
    # Tail-sync each append-only list; offsets hold the NEXT index to mark and
    # only actual growth costs a key derivation.
    set -l started_n (count $_lane_started)
    if test $started_n -ge $_DS_OFF_STARTED
        set -l new_items $_lane_started[$_DS_OFF_STARTED..$started_n]
        set -g _DS_OFF_STARTED (math $started_n + 1)
        for key in (_topo_key $new_items)
            set -g _DS_STARTED_$key 1
        end
    end
    set -l done_n (count $_lane_done)
    if test $done_n -ge $_DS_OFF_DONE
        set -l new_items $_lane_done[$_DS_OFF_DONE..$done_n]
        set -g _DS_OFF_DONE (math $done_n + 1)
        for key in (_topo_key $new_items)
            set -g _DS_DONE_$key 1
        end
    end
    set -l defer_n (count $_lane_deferred)
    if test $defer_n -ge $_DS_OFF_DEFER
        set -l new_items $_lane_deferred[$_DS_OFF_DEFER..$defer_n]
        set -g _DS_OFF_DEFER (math $defer_n + 1)
        for key in (_topo_key $new_items)
            set -g _DS_DEFER_$key 1
        end
    end
end

# _deferred_blocked_refresh — maintain _DBLOCKED_ marks: every package in the
# build list that TRANSITIVELY consumes a deferred one — the memoized answer
# to the waits_on_deferred recursion. Deferred only grows during a run, so the
# marks are monotone and new deferred entries extend the BFS from their own
# tails; a sorted-count change rebuilds from scratch.
function _deferred_blocked_refresh
    if test "$_DS_N" != "$_DB_N"
        set -l stale (set -n | string match -r '^_DBLOCKED_.*$')
        if test (count $stale) -gt 0
            set -e $stale
        end
        set -g _DB_N $_DS_N
        set -g _DB_OFF 1
    end
    set -l n (count $_lane_deferred)
    if test $n -lt $_DB_OFF
        return 0
    end
    set -l new_items $_lane_deferred[$_DB_OFF..$n]
    set -g _DB_OFF (math $n + 1)
    set -l queue_keys (_topo_key $new_items)
    set -l qhead 1
    while test $qhead -le (count $queue_keys)
        set -l key $queue_keys[$qhead]
        set qhead (math $qhead + 1)
        set -l cons_var _TCONSKEYS_$key
        for cons_key in $$cons_var
            set -q _DS_INLIST_$cons_key; or continue
            set -q _DBLOCKED_$cons_key; and continue
            set -g _DBLOCKED_$cons_key 1
            set -a queue_keys $cons_key
        end
    end
end

# True when $pkg transitively depends (within the build list) on a recipe this
# run deferred — used to label unstarted packages honestly: waiting on a
# parked recipe is not the dependency cycle the old message claimed. The graph
# is acyclic (topo_sort validated it), so the recursion terminates. The
# recursion is memoized in the _DBLOCKED_ marks; callers pass packages from
# the build list (unstarted plan rows), and the marks are exactly the
# recursion's answer for those.
function waits_on_deferred -a pkg
    if test (count $_lane_deferred) -eq 0
        return 1
    end
    dispatch_state_refresh
    _deferred_blocked_refresh
    set -l key (_topo_key "$pkg")
    set -q _DBLOCKED_$key
    and return 0
    return 1
end

function pick_next_ready -a solo_ok
    # Print the next package to dispatch. Readiness is decided FIRST and wins
    # always: unstarted, every in-list dep done (external deps ignored), no
    # deferred dep, and the solo_ok=0 core skip (core packages are only
    # dispatched solo). Two pick policies then coexist over the ready set:
    # - force_mode: argv[2..] = optional RESTRICT set, the toolchain-
    #   remediation force queue (2026-10-02). With a restrict set the pick is
    #   FORCE semantics — a queued package may dispatch again even though an
    #   earlier attempt already landed in _lane_started/_lane_done (the
    #   rebuild is the point) — but never while an earlier lane for it is
    #   still in flight (no double dispatch), and a dependency that is itself
    #   queued for rebuild must be rebuilt first.
    # - the build-tools band (2026-10-04 — the group's ONE behavioural
    #   effect): among packages ready NOW, its members are picked before all
    #   other ready packages, and within each band the topo order of
    #   $_lane_sorted is kept. The band therefore reorders pickable
    #   candidates only — never a package past a prerequisite/deferred wait.
    set -l restrict $argv[2..-1]
    set -l force_mode 0
    if test (count $restrict) -gt 0
        set force_mode 1
    end
    # Force mode (the remediation path — rare) keeps the original scan below
    # verbatim: its FORCE semantics deliberately re-dispatch packages that
    # already landed in _lane_started/_lane_done, which the fast path's
    # per-name markers would refuse by construction.
    if test $force_mode -eq 1
    set -l fallback ""
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
        # Build-tools membership is dual with core, so under solo_ok=0 such a
        # member is already skipped above — the band is a no-op on the
        # non-core fallback and core's solo rule stays untouched.
        if contains "$pkg" $_GROUP_build_tools
            echo $pkg
            return 0
        end
        if test -z "$fallback"
            set fallback $pkg
        end
    end
    if test -n "$fallback"
        echo $fallback
        return 0
    end
    return 1
    end

    # Fast path (the common non-force call): same predicate, same
    # first-ready-in-topo-order pick with band-first-with-fallback, over O(1)
    # per-name markers maintained by dispatch_state_refresh instead of
    # `contains` scans — each `contains` re-marshals a V-element list, so the
    # old loop was O(V²·E) list traffic across a run.
    dispatch_state_refresh
    set -l fallback ""
    for j in $_DS_SLOT_IDX
        set -l pkg $_lane_sorted[$j]
        set -l key $_DS_KEYS[$j]
        set -q _DS_STARTED_$key; and continue
        set -q _DS_DONE_$key; and continue
        set -l depkeys_var _DS_DEPKEYS_$key
        set -l ok 1
        for dep_key in $$depkeys_var
            # Deferred first, exactly like the scan above: a deferred dep IS
            # in _lane_done (the lane finished, parked), but its package was
            # never built or installed.
            if set -q _DS_DEFER_$dep_key
                set ok 0
                break
            end
            if not set -q _DS_DONE_$dep_key
                set ok 0
                break
            end
        end
        if test $ok -eq 0
            continue
        end
        # Core packages are only dispatched solo.
        if test $solo_ok -eq 0; and set -q _DS_CORE_$key
            continue
        end
        # Build-tools band: members ready NOW are picked before all other
        # ready packages; the first ready non-member is the fallback (topo
        # order of $_lane_sorted decides within each band).
        if set -q _DS_BAND_$key
            echo $pkg
            return 0
        end
        if test -z "$fallback"
            set fallback $pkg
        end
    end
    if test -n "$fallback"
        echo $fallback
        return 0
    end
    return 1
end

# ─── Lane invocation: one description of the process-boundary argv ───────────
# The seam stays the PROCESS BOUNDARY: `--lane-job` + 8 positional payload
# args (pkg, result file, jobs, four 0|1 flags, and the SKIP mode 0|1|2),
# unchanged. But the shape now
# has one home: lane_argv builds the payload (the spawn) and lane_argv_check
# validates exactly that shape (the handler). Adding a lane flag is a two-line
# edit here plus the lane_job signature — never argv archaeology through a
# count check at the call site.

# lane_argv PKG RESULT_FILE JOBS INSTALL CLEAN SKIP NO_SYNC FORCE → the eight
# payload args, one per line (fish command substitution splits on newlines).
# SKIP is the skip MODE (0 off, 1 -s, 2 --skip-built) — the arity is pinned,
# so the mode rides the existing field instead of a ninth argument.
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
    # The payload is newline-framed (lane_argv prints one field per line), so
    # a control character in the result path would corrupt the 8-arg boundary
    # — the receiving end refuses it explicitly (R-F30 backstop; the producer
    # side gate is where GSA_STATE_DIR is first read).
    if string match -qr '[\x00-\x1f\x7f]' -- "$argv[2]"
        echo "Error: --lane-job received a result path with control characters" >&2
        return 2
    end
    if not string match -qr '^[1-9][0-9]*$' -- "$argv[3]"
        echo "Error: --lane-job received an invalid job count: $argv[3]" >&2
        return 2
    end
    # SKIP ($argv[6]) is a mode (0 off, 1 -s, 2 --skip-built); the other four
    # flags are booleans. One grammar, two shapes — validated where the wire
    # is defined so a future mode value is a deliberate edit at both ends.
    if not string match -qr '^[012]$' -- "$argv[6]"
        echo "Error: --lane-job received an invalid flag: $argv[6]" >&2
        return 2
    end
    for flag in $argv[4..5] $argv[7..8]
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
    # -j normalisation (R-F31): a bare `-j` takes its operand as the NEXT
    # token — dropping only the flag strands that operand in the re-exported
    # MAKEFLAGS. Both spellings (-jN and -j N) are consumed as a pair.
    set -l make_flags
    if set -q MAKEFLAGS
        set -l tokens (string split ' ' -- "$MAKEFLAGS")
        set -l i 1
        while test $i -le (count $tokens)
            set -l flag $tokens[$i]
            if test -n "$flag"
                if string match -qr '^-j[0-9]*$' -- "$flag"
                    if test "$flag" = -j
                        set i (math $i + 1)
                    end
                else
                    set -a make_flags "$flag"
                end
            end
            set i (math $i + 1)
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
        set -l tokens (string split ' ' -- "$NINJAFLAGS")
        set -l i 1
        while test $i -le (count $tokens)
            set -l flag $tokens[$i]
            if test -n "$flag"
                if string match -qr '^-j[0-9]*$' -- "$flag"
                    if test "$flag" = -j
                        set i (math $i + 1)
                    end
                else
                    set -a ninja_flags "$flag"
                end
            end
            set i (math $i + 1)
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
    # anchor branch stays silent and keeps the legacy default); an ok outcome
    # carries the skip CLAIM when one was made (a waived-freshness skip or a
    # --skip-built claim is not the same claim as an untouched archive — the
    # run record row must say which happened: freshness-waived,
    # abi-provider-waived or skip-built); every other outcome has no reason
    # field. The reason, not the waiver line count, is the claim marker:
    # --skip-built claims with nothing waived (freshness analysis is off).
    set -l lane_reason ""
    if test "$rc" = "$lane_outcome_defer"; and set -q _DEFER_REASON
        set lane_reason "$_DEFER_REASON"
    else if test "$rc" = "$lane_outcome_ok"
        if set -q _FRESHNESS_WAIVER_REASON; and test -n "$_FRESHNESS_WAIVER_REASON"
            set lane_reason "$_FRESHNESS_WAIVER_REASON"
        else if set -q _FRESHNESS_WAIVER; and test (count $_FRESHNESS_WAIVER) -gt 0
            set lane_reason freshness-waived
        end
    end
    if not write_lane_result "$result_file" "$pkg_id" "$rc" "$dur" "$lane_reason"
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
    # Run identity first (R-F9): the lock REFUSES a second concurrent run —
    # never queues it — and its holder outlives this process by at most one
    # poll, so a crashed run cannot block the next. With the lock held,
    # everything else in the state dir is provably ownerless: stop orphaned
    # lanes of previous runs (R-F8) and sweep their crash leftovers (R-F34)
    # before the first dispatch.
    if not run_lock_acquire
        return 1
    end
    set -g _RUN_ID "$fish_pid-"(date +%s)
    if set -q _GSA_RUN_ID; and test -n "$_GSA_RUN_ID"
        # Internal fixture seam (same class as _LANE_STOP_GRACE_S): pins the
        # run-scoped result filenames so a test can address them.
        if string match -qr "$_TOPOLOGY_ID_RE" -- "$_GSA_RUN_ID"
            set -g _RUN_ID "$_GSA_RUN_ID"
        else
            ui_error "_GSA_RUN_ID must match $_TOPOLOGY_ID_RE"
            run_lock_release
            return 1
        end
    end
    dispatcher_log "run start: id=$_RUN_ID pid=$fish_pid lanes=$lanes"
    orphan_lane_sweep
    sweep_stale_run_artifacts
    # One run's sync/refresh notes: never carry the previous run's recipes
    # into this summary. Deleted by directory permission, so it works even
    # when an earlier root run left the file root-owned.
    command rm -f -- "$_STATE_DIR/synced.list"
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
            # the cleanup TERM sweep, possibly mid-commit. REPORT-ONLY since
            # 2026-10-04: the probe classifies the lock (held/stale/unknown)
            # and prints the operator command — a killed probe must never be
            # able to delete live pacman state.
            check_pacman_lock (pacman_db_lock_path)
            # Same aftermath window: a TERMed pacman may have died MID-COMMIT
            # (2026-09-24: mtree-only local entry, three packages' installs
            # poisoned until it was repaired). Also report-only: the broken
            # entries are named with their operator repair command.
            check_pacman_db_health (pacman_db_local_path)
            ui_warning "Build interrupted"
            dispatcher_log "Build interrupted (last signal: $_LAST_SIGNAL)"
            set -g _RL_INTERRUPTED 1
            run_lock_release
            return (gsa_signal_exit_rc)
        end

        # Reap finished lanes
        for i in (seq $lanes)
            if test $lane_busy[$i] -eq 1
                set -l rf "$LOG_DIR/.lane.$_RUN_ID.$i.result"
                set -l res_raw (cat "$rf" 2>/dev/null)
                set -l expected_pkg "$lane_pkg[$i]"
                set -l result_ready 0
                set -l result_malformed 0
                set -l result_foreign 0
                set -l decoded
                if test (count $res_raw) -gt 0
                    set decoded (lane_result_decode "$expected_pkg" "$res_raw[1]")
                    set -l dstat $status
                    if test (count $decoded) -ge 3
                        set result_ready 1
                    else if test $dstat -eq 2
                        # FOREIGN identity (R-F9): another run's or an
                        # orphan's line in this slot. Never this lane's
                        # outcome, and never a reason to kill a healthy lane.
                        set result_foreign 1
                    else
                        set result_malformed 1
                    end
                end
                if test $result_ready -eq 0; and \
                    lane_pid_alive "$lane_pid[$i]"
                    # An absent, partial or foreign result is normal while the
                    # child is still running; atomic result publication
                    # prevents a finished child from looking partial here.
                    continue
                end
                if test $result_ready -eq 0; and \
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
                        set -l dstat2 $status
                        if test (count $decoded) -ge 3
                            set result_ready 1
                        else if test $dstat2 -eq 2
                            set result_foreign 1
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
                    dispatcher_log "reap anomaly pkg=$p pid=$lane_pid[$i] state=$lane_state reason="(test $result_foreign -eq 1; and echo foreign-identity; or echo missing-or-malformed)" raw=$raw_joined"
                    set stop_starting 1
                    set -g _DASHBOARD_LAST_EVENT "$_UI_ICON_ERROR lane lost $p"
                end

                # `command rm` — the host's fish `rm` FUNCTION trashes
                # instead of deleting (see sweep_stale_run_artifacts).
                command rm -f -- "$rf"
                set -l finished_pid $lane_pid[$i]
                set lane_busy[$i] 0
                set lane_pkg[$i] ""
                set lane_start[$i] ""
                set lane_pid[$i] ""
                if test -n "$finished_pid"
                    # Never kill a lane over a foreign/malformed file (R-F9):
                    # the child is already gone here — classify and reap it.
                    wait "$finished_pid" 2>/dev/null
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
                        # A skip accepted on a freshness waiver is not the same
                        # claim as an untouched archive: the wire's reason names
                        # it on the row (the empty wire keeps the legacy ok).
                        set -l ok_row_reason ok
                        if test -n "$wire_reason"
                            set ok_row_reason "$wire_reason"
                        end
                        run_record_row "$p" succeeded 0 $dur $ok_row_reason
                        if test -n "$wire_reason"
                            set -g _DASHBOARD_LAST_EVENT "$_UI_ICON_OK completed $p ($wire_reason)"
                        else
                            set -g _DASHBOARD_LAST_EVENT "$_UI_ICON_OK completed $p"
                        end
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
                            # Row reason taxonomy for an honest non-zero rc
                            # (R-F27): a signal outcome keeps its SIGNAL name
                            # (the lane's own handler wrote 129/130/143 — the
                            # reason token is lane_outcome_name's), a builder-
                            # mutex timeout is its own row reason (the rc
                            # collapses to failed on the wire, but "the queue
                            # outlived the wait" is not "the build broke" —
                            # 2026-10-04; the named line lands in the package
                            # log from run_pacman_locked and the dep-install
                            # shim alike), everything else is build-failed.
                            set -l row_reason build-failed
                            switch (lane_outcome_name $rc)
                                case signal-hup signal-int signal-term
                                    set row_reason (lane_outcome_name $rc)
                                case '*'
                                    if grep -q 'builder pacman mutex timed out' (package_log_file "$p") 2>/dev/null
                                        set row_reason mutex-timeout
                                    end
                            end
                            run_record_row "$p" failed $rc $dur $row_reason
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
                            if test -n "$wire_reason"
                                printf "  %s %s (%s) — SKIPPED (%s) — log: %s\n" \
                                    "$_UI_ICON_OK" $p (fmt_dur $dur) "$wire_reason" (package_log_file "$p")
                            else
                                printf "  %s %s (%s)\n" "$_UI_ICON_OK" $p (fmt_dur $dur)
                            end
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
                set -l rf "$LOG_DIR/.lane.$_RUN_ID.$i.result"
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
                # Result-slot settle (R-F33): the clear used to be an
                # unchecked `rm -f` AFTER the lane was marked busy — a leftover
                # that survived it would decode malformed and get a healthy
                # just-started lane killed as lane-lost. Settle ownership
                # through ensure_log_writable (a root-owned crash leftover is
                # repaired/quarantined there), then clear and VERIFY: an
                # unremovable result is a named dispatch refusal, never a
                # silent time bomb for the reap.
                # `command rm`: the host's fish `rm` FUNCTION trashes instead
                # of deleting, which "succeeds" on a DIRECTORY left in the
                # slot and defeats the verification below — the external rm
                # refuses a directory and the gate names it.
                if not ensure_log_writable "$rf"; or not command rm -f -- "$rf"; or test -e "$rf"
                    ui_error "cannot clear a stale lane result — refusing to dispatch $next"
                    echo "  result slot: $rf"
                    set -a failed $next
                    run_record_row "$next" failed 1 0 result-clear-failed
                    set stop_starting 1
                    continue
                end
                set -a _lane_started $next
                set lane_busy[$i] 1
                set lane_pkg[$i] $next
                set lane_start[$i] (date +%s)
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
                _GSA_LANE_WATCHDOG_PID=$fish_pid \
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

        # Foreground tracking (R-F15): fish defers --on-signal handlers until
        # an in-flight FOREGROUND command exits (measured on fish 4.9.3: a
        # signal at t=0.5 s to `sleep 4` ran the handler at t=4.0 s), but runs
        # them promptly during `wait` on a backgrounded job. The poll sleep is
        # therefore a tracked background child: the handler runs at the signal
        # and signals the tracked pid ("signal both") so this wait ends now.
        sleep 0.5 &
        set -g _FG_CHILD_PID $last_pid
        wait $_FG_CHILD_PID 2>/dev/null
        set -g _FG_CHILD_PID ""
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
    run_lock_release
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
# rc-99 lane_outcome_defer amendment (docs call it the _ANCHOR_DEFER_RC
# amendment): a parked recipe, not a failed build — a named deferral refusal,
# and the reason token says which). rc and dur are integers (dur in seconds)
# or '-' when the package never produced one. reason is a kebab-case token:
#   ok                   succeeded
#   freshness-waived     succeeded WITHOUT building: -s skipped an archive
#                        whose selected Git ref moved fewer than
#                        GSA_VCS_SKIP_TOLERANCE commits (default 5). The named
#                        waiver line lives in the package log; the row's
#                        reason keeps the waiver from claiming to be ok.
#   abi-provider-waived  succeeded WITHOUT building: -s skipped an archive of
#                        a recipe marked .gsa-abi-provider (e.g. llvm-git) —
#                        mere upstream movement can never rebuild a matched
#                        ABI provider. Same loud-line plumbing as above.
#   build-failed         lane ran, makepkg/exits non-zero (rc is in the row)
#   mutex-timeout        failed on the builder pacman MUTEX wait (flock rc
#                        75): the queue outlived the wait and the
#                        transaction never ran — not a build or pacman error
#   signal-hup           failed: the lane child was killed by SIGHUP (rc=129,
#                        lane_outcome_name's display form)
#   signal-int           failed: the lane child was killed by SIGINT (rc=130)
#   signal-term          failed: the lane child was killed by SIGTERM (rc=143)
#   lane-lost            reap anomaly: no valid lane result (rc=125)
#   log-unwritable       dispatch refused: the package log could not be opened
#   result-clear-failed  dispatch refused: the run-scoped result slot could
#                        not be cleared for the lane (the write failed)
#   anchoring-refused    deferred (rc=99): checksum anchoring refused
#   upstream-unverified  deferred (rc=99): -s could not confirm the recorded
#                        refs against upstream after transport retries
#   source-unfetchable   deferred (rc=99): sources absent at anchoring time
#                        and the consumer chain can absorb the wait
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

# Register the run's plan once, before dispatch. The 10 fixed arguments are the
# continuation state (mirrored by continuation_args) plus the selection-source
# scalar; the payload is the topological order of the selection.
function run_record_plan -a lanes jobs intensity install force no_deps no_sync allow_broken no_register source
    set -g _RL_ROWS
    set -g _RL_REMAINING
    set -g _RL_SUCCEEDED
    set -g _RL_FAILED
    set -g _RL_DEFERRED
    set -g _RL_BLOCKED 0
    set -g _RL_SUDO_NOTE ""
    set -g _RL_INTERRUPTED 0
    set -g _RR_SOURCE "$source"
    set -g _RR_ORDER $argv[11..-1]
    set -g _RR_CONT_LANES "$lanes"
    set -g _RR_CONT_JOBS "$jobs"
    set -g _RR_CONT_INTENSITY "$intensity"
    set -g _RR_CONT_INSTALL "$install"
    set -g _RR_CONT_FORCE "$force"
    set -g _RR_CONT_NO_DEPS "$no_deps"
    set -g _RR_CONT_NO_SYNC "$no_sync"
    set -g _RR_CONT_ALLOW_BROKEN "$allow_broken"
    set -g _RR_CONT_NO_REGISTER "$no_register"
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
    # Keyed, one-pass rewrite of the old `contains "$pkg" $rowed` + nested row
    # scan (O(N²) at 653 packages): rows and the started set are published
    # under _topo_key marks (function-scoped — finalize is the only writer),
    # so the never-classified sweep and the topological ordering are each one
    # linear walk. First row per package wins, exactly like the old nested
    # scan's `break`.
    for row in $_RL_ROWS
        set -l row_var _RRROW_(_topo_key (string split -f 1 '|' -- "$row"))
        set -q $row_var; and continue
        set -f $row_var "$row"
    end
    for pkg in $_lane_started
        set -f _LRSTARTED_(_topo_key "$pkg") 1
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
    set -l order_keys (_topo_key $_RR_ORDER)
    set -l i 0
    for pkg in $_RR_ORDER
        set i (math $i + 1)
        set -l row_var _RRROW_$order_keys[$i]
        set -q $row_var; and continue
        if test (count $_lane_started) -gt 0; and set -q _LRSTARTED_$order_keys[$i]
            run_record_row "$pkg" interrupted - - interrupted-mid-build
        else
            run_record_row "$pkg" never-started - - $ns_reason
        end
        set -f $row_var "$_RL_ROWS[-1]"
    end
    set -l ordered
    for key in $order_keys
        set -l row_var _RRROW_$key
        set -q $row_var; and set -a ordered $$row_var
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

# abort_before_dispatch — the ONE pre-dispatch interrupt exit (R-F27),
# factored out of the check just before run_lanes so every pre-dispatch phase
# boundary (the ABI gate's per-anchor / per-provider iterations included) can
# honour the latch promptly instead of grinding to the end of the scan. The
# run record is completed (every row never-started / interrupted-before-start)
# and rendered, and the exit status is the signal's own (gsa_signal_exit_rc:
# 129/130/143). During dispatch the latch stays with run_lanes' loop head —
# its latch+drain semantics are untouched. It PRINTS the summary and the
# machine block, so it must never be wrapped in a command substitution;
# callers do `abort_before_dispatch; return $status`.
function abort_before_dispatch
    printf '\n'
    ui_warning "Build interrupted"
    dispatcher_log "Build interrupted (last signal: $_LAST_SIGNAL, before dispatch)"
    set -g _RL_INTERRUPTED 1
    run_record_finalize
    print_run_summary interrupted
    set -l interrupt_rc (gsa_signal_exit_rc)
    print_run_record interrupted $interrupt_rc
    return $interrupt_rc
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
#               --no-register-ignorepkg
#   replaced    -g/--group, N..M ranges,             replaced by the package
#               package references                  list ($remaining/argv)
#   not-mirrored -c/--clean, -s/--skip               deliberately NOT mirrored:
#               --skip-built --vcs-skip-tolerance    -c would wipe the archives
#                                                   a resume needs, and the
#                                                   skip modes are the user's
#                                                   call (the tip says to add
#                                                   them)
#   not-mirrored -n -l -ia -cc -ccc -ln              one-shot actions and
#               --audit --topology -h --help         read-only modes
#   not-mirrored --lane-job --stale-lock-check       hidden seams: process-exit
#               --local-db-check --install-decide    interfaces, never a
#               --audit-lint --register-ignorepkg    command a resume replays
#               --install-register
set -g _CONTINUATION_RULES \
    '--lanes|value' \
    '--jobs|value' \
    '--intensity|value' \
    '-i --install -fi --forceinstall|flavour' \
    '--no-deps|semantics' \
    '--no-sync|semantics' \
    '--allow-broken-rustc|semantics' \
    '--no-register-ignorepkg|semantics' \
    '-g --group, N..M ranges, package references|replaced' \
    '-c --clean|not-mirrored' \
    '-s --skip --skip-built --vcs-skip-tolerance|not-mirrored' \
    '-n --dry-run -l --list -ia --installall -cc --cleanup -ccc --nuclear -ln --link-sources --audit --topology -h --help|not-mirrored' \
    '--lane-job --stale-lock-check --local-db-check --install-decide --install-register --audit-lint --register-ignorepkg|not-mirrored'

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
                        case --no-register-ignorepkg
                            if test "$_RR_CONT_NO_REGISTER" = "1"
                                set -a out --no-register-ignorepkg
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
                set -l deferred_count (count $deferred)
                ui_warning "$deferred_count recipe(s) deferred — the rest of the dispatch continued; the parked recipes below were not built."
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
            echo "(Tip: add -s so already-built pkgs are skipped, or --skip-built to skip the built set without freshness checks.)"
            echo "(Tip: --vcs-skip-tolerance N sets the -s waive threshold.)"
        end
    end

    # Ambient-knob gap (2026-09-26): GSA_TARGET_CPU and GSA_STATE_DIR are
    # ENVIRONMENT inputs — never baked into a continuation command — so a
    # continuation must run with the same ambient values as this run.
    set -l ambient
    set -q GSA_TARGET_CPU; and set -a ambient GSA_TARGET_CPU
    set -q GSA_STATE_DIR; and set -a ambient GSA_STATE_DIR
    # GSA_CPU_THREADS/GSA_MEMORY_GIB re-derive the whole plan (core_jobs among
    # it) every run, and GSA_VCS_SKIP_TOLERANCE changes -s skip decisions at
    # run time — a continuation under different pins silently re-plans, so all
    # three must match this run's env (never baked into the command).
    set -q GSA_CPU_THREADS; and set -a ambient GSA_CPU_THREADS
    set -q GSA_MEMORY_GIB; and set -a ambient GSA_MEMORY_GIB
    # A --vcs-skip-tolerance value is command text, not ambient state: the
    # flag writes GSA_VCS_SKIP_TOLERANCE only because that env var is how lane
    # children receive the effective value, and the tip already tells the user
    # to re-add the flag — warning about an env var they never set would name
    # the wrong knob.
    if set -q GSA_VCS_SKIP_TOLERANCE; and not set -q _GSA_TOLERANCE_FROM_FLAG
        set -a ambient GSA_VCS_SKIP_TOLERANCE
    end
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
        set -l key (_topo_key "$id")
        set -l dep_var _TDEP_$key
        set -l edge_values
        if set -q $dep_var
            set edge_values $$dep_var
        end
        # Raw record tags, comma-joined in record order: the data channel
        # round-trips every tag (app-cluster=<name> included) unchanged. The
        # vocabulary is closed and loader-validated, so raw == the old
        # abi-only normalisation for every pre-existing record. The loader
        # stores the raw row in _TTAGS_<key> — the old scan re-split every
        # _TAGS row for every package (O(P×T) command substitutions).
        set -l tag_var _TTAGS_$key
        set -l tags_str ""
        if set -q $tag_var
            set tags_str "$$tag_var"
        end
        set -l groups_str (string join ',' $group_values)
        set -l edges_str (string join ',' $edge_values)
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
    echo "                    plus their .gsa-vcs-revisions sidecars; symlinks"
    echo "                    are preserved (never deleted or followed)"
    echo "  -ccc, --nuclear   Remove pulled sources: src/pkg/build dirs, source git"
    echo "                    clones, and downloaded source tarballs (asks first)"
    echo "  --audit           Read-only report of legacy paths, package drift,"
    echo "                    stale runtime/error artifacts, cargo/rustc recipes"
    echo "                    with no rust-git edge, the recipe-contract lint"
    echo "                    families (provides-versioning, purged tools,"
    echo "                    provides swaps, ABI closure, ABI exposure), and"
    echo "                    installed PGO packages still carrying"
    echo "                    -fprofile-generate or -Cprofile-generate payloads"
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
    echo "  --no-register-ignorepkg"
    echo "                    Skip the dynamic IgnorePkg registration an install run"
    echo "                    normally performs before pacman -U (it appends the"
    echo "                    built package names to the [options] closure in"
    echo "                    pacman.conf). Only for a run that must install"
    echo "                    without touching pacman.conf — the skip is loud."
    echo "  -c, --clean       Clean build artifacts before building"
    echo "  -s, --skip        Skip fresh archives only when each VCS source ref matches"
    echo "                    its recorded revision; an unusable baseline rebuilds"
    echo "                    once if refs resolve. A Git ref that ADVANCED still"
    echo "                    skips while the move is fewer than 5 commits (a loud,"
    echo "                    named freshness waiver, recorded as the row reason"
    echo "                    freshness-waived; --vcs-skip-tolerance N, or env"
    echo "                    GSA_VCS_SKIP_TOLERANCE — the flag wins — overrides"
    echo "                    the 5, positive integers only); 5 or more commits"
    echo "                    rebuilds. A recipe marked .gsa-abi-provider (an ABI"
    echo "                    provider, e.g. llvm-git) skips on ANY upstream"
    echo "                    movement (loudly, row reason abi-provider-waived:"
    echo "                    rebuilding it invalidates every dependent's ABI)."
    echo "                    A ref upstream cannot answer even"
    echo "                    after transport retries parks that recipe (deferred:"
    echo "                    nothing is skipped or built, the rest of the run"
    echo "                    continues, exit stays non-zero)."
    echo "  --skip-built      Skip anything already built for the recipe's CURRENT"
    echo "                    version: a complete, payload-valid archive set stays"
    echo "                    skipped (row reason skip-built) — freshness analysis"
    echo "                    is OFF (no PKGBUILD-vs-archive mtime compare, no"
    echo "                    upstream VCS probes, no network, no waivers). An"
    echo "                    old-version or incomplete set still rebuilds. With"
    echo "                    -i the skipped package still installs. Combined with"
    echo "                    -s, --skip-built wins."
    echo "  --vcs-skip-tolerance N"
    echo "                    The -s waive threshold: a moved Git ref still skips"
    echo "                    while the move is fewer than N commits. Overrides"
    echo "                    GSA_VCS_SKIP_TOLERANCE (default 5); positive"
    echo "                    integers only."
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
    echo "               GSA_CPU_THREADS, GSA_MEMORY_GIB, GSA_TARGET_CPU,"
    echo "               GSA_VCS_SKIP_TOLERANCE"
    echo "               override runtime state, parallelism, and optional CPU tuning."
    echo "               A flag beats its env twin: --vcs-skip-tolerance overrides"
    echo "               GSA_VCS_SKIP_TOLERANCE."
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
    echo "  build-all.fish glib2-git            Rebuild it + its consumers (gtk4-git,"
    echo "                                      gimp-git, …) — use --no-deps to avoid this"
    echo "  build-all.fish -g git 22..38        Build packages 22-38 of the git group"
    echo "  build-all.fish -n -g core           Dry-run: show the core build order"
    echo "  build-all.fish -n                   Show full build order (dry run)"
    echo "  build-all.fish -ia --overwrite '*'  Same, passing pacman options through"
    echo "  build-all.fish -cc                  Delete all built package archives"
    echo "                                      and their VCS revision sidecars"
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
            case build-tools
                set desc "Scheduling class — ready members dispatch before all other ready packages (never over build-order edges); dual with core"
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
    set -l no_register_flag 0
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
                # A skip MODE, not a boolean: --skip-built (2) wins over -s (1)
                # however the two are ordered, so -s never demotes it.
                if test "$skip_flag" != 2
                    set skip_flag 1
                end
            case --skip-built
                set skip_flag 2
            case --vcs-skip-tolerance
                if test (count $args) -lt 2
                    ui_error "--vcs-skip-tolerance requires an argument"
                    return 1
                end
                if not string match -qr '^[1-9][0-9]*$' -- "$args[2]"
                    ui_error "--vcs-skip-tolerance expects a positive integer, got '$args[2]'"
                    return 1
                end
                # The env var is the transport to lane children (lane_argv's
                # payload is pinned), so the flag writes it after validation
                # and stays the single source of truth for the effective
                # value: vcs_skip_tolerance_resolve reads only the env var.
                set -gx GSA_VCS_SKIP_TOLERANCE "$args[2]"
                set -g _GSA_TOLERANCE_FROM_FLAG 1
                set -e args[2]
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
            case --no-register-ignorepkg
                # Deliberate escape hatch for the dynamic IgnorePkg
                # registration (install_register_ignorepkg): skip it, loudly,
                # for a run that must install without touching pacman.conf.
                # The decision rides as an EXPORTED variable so lane children
                # see it without a change to the pinned lane_argv codec.
                set no_register_flag 1
                set -gx _IGNOREPKG_REGISTER 0
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

    # Register the run record's plan once for this run (the cluster's input
    # contract — see the run-record cluster below run_lanes). Registered here,
    # BEFORE the ABI gate, because a ^C anywhere in the pre-dispatch phase must
    # be able to render a record on its abort path. selection-source renders
    # as groups=… packages=… ranges=… with '-' for an absent part. Read-only
    # modes (-n/-l) never render the record and stay unregistered.
    if test $dry_run -eq 0; and test $list_flag -eq 0
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
            "$allow_broken_rustc" "$no_register_flag" \
            "groups=$src_groups packages=$src_packages ranges=$src_ranges" $sorted
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
            # Every pre-dispatch phase boundary honours the interrupt latch:
            # a ^C during the gate aborts on the next iteration (or at the
            # loop's end below), never after the full scan.
            if test "$_INTERRUPT_HANDLED" = "1"
                abort_before_dispatch
                return $status
            end
            test (package_abi_severity $anchor) = must; or continue
            has_abi_tagged_dependency $anchor; and continue
            for member in (abi_batch_dependents $anchor)
                contains $member $sorted; and continue
                abi_id_installed "$member"; or continue
                switch (package_abi_severity $member)
                    case must
                        set -a batch_missing (printf '%s %s' $anchor $member)
                    case should
                        set -a batch_candidates $member
                end
            end
        end
        if test "$_INTERRUPT_HANDLED" = "1"
            abort_before_dispatch
            return $status
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

        # ABI-drift guard layer 2 — batch tightening on soname drift. The
        # tag-based batch above is the policy relation; this is the CONCRETE
        # one: any provider whose soname-provides set (committed .SRCINFO
        # bare stems) differs from the installed stock equivalent's provides
        # (abi_soname_provides_changed — pure gate logic, no builds) drags
        # its FULL in-tree consumer closure into the batch
        # (abi_consumer_closure: .SRCINFO name matching + topology edges).
        # An installed closure member omitted from the selection is refused
        # exactly like an omitted abi=must member: the provider's new surface
        # would land beside a consumer still built against the old one. A
        # member that is not installed has nothing to protect and never
        # gates; read-only modes stay exempt.
        set -l abi_open
        for provider in $sorted
            if test "$_INTERRUPT_HANDLED" = "1"
                abort_before_dispatch
                return $status
            end
            abi_soname_provides_changed "$provider"; or continue
            for member in (abi_consumer_closure "$provider")
                contains -- "$member" $sorted; and continue
                abi_pkg_installed "$member"; or continue
                set -a abi_open (printf '%s %s' $provider $member)
            end
        end
        if test "$_INTERRUPT_HANDLED" = "1"
            abort_before_dispatch
            return $status
        end
        if test (count $abi_open) -gt 0
            set abi_open (printf '%s\n' $abi_open | sort -u)
            set -l first_pair (string split ' ' -- $abi_open[1])
            ui_error "refusing to build $first_pair[1] without $first_pair[2] — its soname provides changed, so the whole consumer closure must rebuild in the same selection"
            echo "  $first_pair[1]'s soname provides differ from the installed stock package's provides:"
            echo "  installing it beside an installed consumer leaves that consumer broken the"
            echo "  moment the archive lands. Missing consumer(s) of the closure:"
            for entry in $abi_open
                set -l pair (string split ' ' -- $entry)
                echo "  missing: $pair[2] — add $pair[2] to the selection (or use --no-deps only for leaves)"
            end
            echo "  if the consumers cannot rebuild yet, build without -i and install the whole"
            echo "  built set together with -ia once the closure is complete."
            return 1
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
        abort_before_dispatch
        return $status
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
            return (gsa_signal_exit_rc)
    end
    return 1
end

# ─── Sourced leaf modules (Design C split) ──────────────────────────────────
# lib/sources.fish and lib/audit.fish were cut out of this file verbatim.
# Sourced here — before load_project_config and the hidden seam blocks below —
# so the loader, the seams and main all resolve the same flat function
# namespace as before the split.
if not source "$SCRIPT_DIR/lib/sources.fish"
    echo "build-all.fish: cannot source $SCRIPT_DIR/lib/sources.fish" >&2
    exit 1
end
if not source "$SCRIPT_DIR/lib/audit.fish"
    echo "build-all.fish: cannot source $SCRIPT_DIR/lib/audit.fish" >&2
    exit 1
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
# cleanup_active_lanes and exits with the signal's own status
# (gsa_signal_exit_rc: 129/130/143) via the permanent "Build interrupted"
# event. A SECOND signal escalates to an immediate SIGKILL sweep. HUP joins
# INT/TERM here: it previously had NO handler and orphaned live lanes outright.
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
    # Foreground tracking (R-F15): fish ran THIS handler only because the
    # dispatcher waits on background children; the tracked foreground child
    # is signalled too so the wait returns now instead of at the child's
    # natural exit ("signal both").
    if test -n "$_FG_CHILD_PID"
        command kill -TERM "$_FG_CHILD_PID" 2>/dev/null
    end
    if test "$_INTERRUPT_HANDLED" = "1"
        # SECOND signal: the user said NOW (R-F15). The normal teardown is a
        # TERM→grace→KILL sweep that may take the whole grace; escalate to an
        # immediate SIGKILL sweep with no grace, then let the interrupt path
        # finish the bookkeeping.
        set -g _SIGNAL_ESCALATED 1
        dispatcher_log "signal: $sig is the SECOND signal — immediate SIGKILL sweep of active lanes (grace skipped)"
        kill_active_lanes_immediate
    end
    set -g _INTERRUPT_HANDLED 1
end

# kill_active_lanes_immediate — the second-signal escalation: SIGKILL every
# pid of every active lane pgrp NOW, no TERM, no grace. Forensics keep the
# escalate line shape so the two kill paths read alike in dispatcher.log.
function kill_active_lanes_immediate
    for i in (seq (count $_ACTIVE_LANE_PIDS))
        set -l lane_pid "$_ACTIVE_LANE_PIDS[$i]"
        set -l pkg ''
        if test $i -le (count $_ACTIVE_LANE_PKGS)
            set pkg "$_ACTIVE_LANE_PKGS[$i]"
        end
        set -l pkg_label '-'
        test -n "$pkg"; and set pkg_label "$pkg"
        for process_id in (lane_processes "$lane_pid")
            dispatcher_log "escalate: pid=$process_id pgid=$lane_pid pkg=$pkg_label SIGKILL immediately (second signal)"
            kill -KILL "$process_id" 2>/dev/null
        end
    end
end

# gsa_signal_exit_rc — the process exit status an interrupted run owes its
# caller: 129/130/143 for HUP/INT/TERM from the signal that actually arrived
# (_LAST_SIGNAL), never a flat 130 (R-F27). No signal recorded keeps the
# historical 130.
function gsa_signal_exit_rc
    switch "$_LAST_SIGNAL"
        case HUP
            echo $lane_outcome_hup
        case TERM
            echo $lane_outcome_term
        case '*'
            echo $lane_outcome_int
    end
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
    # Parent-liveness watchdog (R-F8): if the dispatcher is SIGKILLed, this
    # setsid lane would keep building — and installing (`sudo pacman -U`) —
    # unattended, overlapping the next run (the OOM hazard). A tiny external
    # watcher (fish cannot background a function) polls the dispatcher pid
    # and this lane pid; when the dispatcher vanishes it TERMs this whole
    # process group — the makepkg child included — and SIGKILLs after a short
    # settle. It exits by itself once this lane does. Only dispatcher-spawned
    # lanes carry the marker env; direct --lane-job seam runs spawn none.
    if set -q _GSA_LANE_WATCHDOG_PID; and test -n "$_GSA_LANE_WATCHDOG_PID"
        set -l my_pgid (ps -o pgid= -p $fish_pid 2>/dev/null | string trim)
        if test -n "$my_pgid"
            sh -c 'trap "" TERM
state=$(ps -o stat= -p "$1" 2>/dev/null)
while [ -n "$state" ]; do
    case $state in *Z*) break ;; esac
    own=$(ps -o stat= -p "$3" 2>/dev/null)
    [ -n "$own" ] || exit 0
    case $own in *Z*) exit 0 ;; esac
    sleep 1
    state=$(ps -o stat= -p "$1" 2>/dev/null)
done
kill -TERM -- "-$2" 2>/dev/null
sleep 2
kill -KILL -- "-$2" 2>/dev/null' \
                sh "$_GSA_LANE_WATCHDOG_PID" "$my_pgid" "$fish_pid" &
        end
    end
    lane_job $argv[2..-1]
    exit $status
end

# Hidden fixture seam (same precedent as --lane-job): run the production lock
# probe against an arbitrary path. rc 0 = absent, 1 = present (held/stale/
# unproven). REPORT-ONLY: the probe never removes anything — it classifies
# the lock and prints the operator removal command.
# No GSA_* test knob — the builder honours only the GSA_* inputs --help lists.
if test (count $argv) -gt 0; and test "$argv[1]" = --stale-lock-check
    if test (count $argv) -ne 2
        echo "Error: --stale-lock-check expects exactly one lock path" >&2
        exit 2
    end
    check_pacman_lock "$argv[2]"
    exit $status
end

# Hidden fixture seam (same precedent as --stale-lock-check): run the
# local-db integrity probe against an arbitrary directory. rc 0 = healthy;
# 1 = broken entries present. REPORT-ONLY: the probe names them and prints
# the operator repair command but never removes them. Never points at the
# host db unless a caller passes it.
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

# Hidden install-pipeline seam: the DYNAMIC IgnorePkg registration step's
# db.lck deferral + conf write, runnable under the builder's pacman mutex.
# install_register_ignorepkg is the ONLY caller — it has already resolved the
# names (install_register_names) and the target conf, and runs this seam
# through run_pacman_locked so the write serializes with every other
# pacman-state mutation. fish's `exec` takes no redirections, so a fish
# process cannot hold a flock across its own code: the mutex always wraps an
# external command, and this seam is that command.
#   fish build-all.fish --install-register <pacman-conf> <subject> <name>...
# SUBJECT is the phrase register_ignorepkg_names reports these names with.
# rc 0 = the closure covers the names afterwards (nothing-to-append counts),
# 1 = refusal, or the bounded db.lck wait timed out; 2 = bad usage.
if test (count $argv) -gt 0; and test "$argv[1]" = --install-register
    if test (count $argv) -lt 4; or test -z "$argv[2]"; or test -z "$argv[3]"
        echo "Error: --install-register expects <pacman-conf> <subject> <name>..." >&2
        exit 2
    end
    # The deferral (2026-10-05): never rewrite pacman.conf while an alpm
    # transaction holds the db lock — the write is a cp, not an atomic rename,
    # so a concurrent transaction could read a half-written conf. Bounded
    # wait, and the lock is NEVER deleted here.
    if not pacman_lock_wait_clear (pacman_db_lock_path)
        exit 1
    end
    register_ignorepkg_names "$argv[2]" "$argv[3]" $argv[4..-1]
    exit $status
end

# Hidden fixture seam (same precedent as --stale-lock-check/--local-db-check):
# run ONE workspace-audit lint against the loaded workspace — no build, no
# network, no host state. (The IgnorePkg closure lint retired 2026-10-5 with
# the static closure contract: IgnorePkg is now registered dynamically at
# install time, so there is no static closure left to lint.)
#   fish build-all.fish --audit-lint <provides|purged|swap|abi-closure|abi-exposure>
# Output: one finding line per finding (prefix `provides: `/`purged: `/
# `swap: `/`abi-closure: `/`exposure: `) followed by
# `audit-lint <name>: clean`, `audit-lint <name>: N finding(s)` or
# `audit-lint <name>: skipped`.
# rc 0 = the lint RAN — a finding never changes the exit status (report-only,
# the same contract --audit has) — 2 = usage. No GSA_* test knob.
if test (count $argv) -gt 0; and test "$argv[1]" = --audit-lint
    if test (count $argv) -ne 2
        echo "Error: --audit-lint expects <provides|purged|swap|abi-closure|abi-exposure>" >&2
        exit 2
    end
    switch $argv[2]
        case provides purged swap abi-closure abi-exposure
        case '*'
            echo "Error: --audit-lint expects provides, purged, swap, abi-closure or abi-exposure" >&2
            exit 2
    end
    set -l lint_findings
    switch $argv[2]
        case provides
            set lint_findings (audit_lint_provides)
        case purged
            set lint_findings (audit_lint_purged)
        case swap
            set lint_findings (audit_lint_swap)
        case abi-closure
            set lint_findings (audit_lint_abi_closure)
        case abi-exposure
            set lint_findings (audit_lint_abi_exposure)
    end
    for finding in $lint_findings
        echo "$finding"
    end
    if test (count $lint_findings) -eq 1; and string match -q "$argv[2]: skipped*" -- $lint_findings[1]
        echo "audit-lint $argv[2]: skipped"
    else if test (count $lint_findings) -eq 0
        echo "audit-lint $argv[2]: clean"
    else
        echo "audit-lint $argv[2]: "(count $lint_findings)" finding(s)"
    end
    exit 0
end

# Hidden mutation seam (same rc vocabulary as --install-decide): close the
# IgnorePkg closure of a pacman.conf from the workspace name universe — the
# BACKFILL of docs/MEMORY.md rule 9. Since 2026-10-05 the contract is dynamic
# (install_register_ignorepkg registers each built package's names before
# pacman -U); this seam exists to bring an EXISTING conf up to date in one
# shot, and the static --audit closure lint it used to pair with is retired.
# Unlike the lints it is NOT report-only: it appends the missing names, so it
# may modify its target.
#   fish build-all.fish --register-ignorepkg [pacman-conf]
# Default target /etc/pacman.conf. The universe is pkgbase+pkgname of every
# committed .SRCINFO under packages/; the target is parsed exactly like pacman
# (cumulative `IgnorePkg =` inside [options] only — a repo-section line is
# dropped, with a warning) and the missing names land as ~10-per-line
# `IgnorePkg =` lines inside [options], after the last existing one there.
# Idempotent: a complete closure appends nothing (and writes nothing).
# rc 0 = the closure is complete afterwards (the verification comm -23 is
# empty; nothing-to-append counts), 1 = refusal with nothing changed (a
# missing/stale .SRCINFO names its recipe and blocks; a non-user-writable
# target escalates with `sudo -n` ONLY and fails fast when that is
# unavailable — the builder never prompts; backup clash or failed
# write/post-check also refuse), 2 = bad usage. A dated pre-image backup
# (<conf>.bak-YYYYMMDD) is written before the first modification only.
# Fixture-path targets (user-writable) never invoke sudo:
# tests/ignorepkg-register.sh. No GSA_* test knob.
if test (count $argv) -gt 0; and test "$argv[1]" = --register-ignorepkg
    if test (count $argv) -gt 2
        echo "Error: --register-ignorepkg expects at most one pacman.conf path" >&2
        exit 2
    end
    set -l register_conf /etc/pacman.conf
    if test (count $argv) -eq 2
        if test -z "$argv[2]"
            echo "Error: --register-ignorepkg pacman.conf path must not be empty" >&2
            exit 2
        end
        set register_conf "$argv[2]"
    end
    register_ignorepkg "$register_conf"
    exit $status
end

main $argv
