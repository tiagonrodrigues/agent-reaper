#!/bin/bash
# reap: kill zombie processes left behind by AI-agent wrappers.
# https://github.com/tiagonrodrigues/agent-reaper
#
# Usage:
#   reap                    Show status (last run, schedule, recent kills)
#   reap preview            Dry-run: show what would be killed, kill nothing
#   reap run                Kill zombies now
#   reap disk [run]         Idle agent worktrees: preview, or move deps to the Trash now
#   reap logs [-f]          Tail the log
#   reap config             Open config in $EDITOR
#   reap install            (Re)install the LaunchAgent
#   reap uninstall [--purge]
#   reap --version | --help

set -u
# Note: `set -e` is intentionally avoided. reap should never crash on a single
# misbehaving pattern; each rule is isolated and errors are logged.

# =============================================================================
# CONSTANTS
# =============================================================================
readonly REAP_VERSION="0.11.0"
readonly REAP_LABEL="co.tiagor.agent-reaper"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agent-reaper"
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/share}/agent-reaper"
readonly CONFIG_DIR LOG_DIR
readonly CONFIG_FILE="$CONFIG_DIR/config.sh"
readonly LOG_FILE="$LOG_DIR/reap.log"
readonly CANDIDATE_STATE_FILE="$LOG_DIR/detached-candidates.tsv"

# Safety: max PIDs a single rule may kill in one run. If exceeded, rule is
# aborted and logged. Something's probably wrong (user pattern too broad).
readonly MAX_KILLS_PER_RULE=50

# Safety: hard blocklist. Patterns matching any of these substrings are
# *never* killed, regardless of user config. Extending this list is how we
# stay safe against user mistakes.
readonly BLOCKLIST=(
    "launchd"
    "kernel_task"
    "WindowServer"
    "loginwindow"
    "Finder"
    "Dock.app"
    "SystemUIServer"
    "Spotlight"
    "/usr/libexec/"
    "/System/Library/"
    "sshd"
    " ssh "
    "syslogd"
    "mdworker"
    "mds_stores"
    "/bin/bash"
    "/bin/zsh"
    "/bin/sh"
    "/bin/dash"
    "/usr/bin/fish"
    "reap.sh"
    "/reap "
    "/reap run"
    "/reap preview"
)

# Interactive browsers are user applications, not agent runtime. Their helper
# processes can legitimately sustain high CPU/RSS during calls, screen sharing,
# video playback, and WebGL. Generic resource rules must never terminate them.
readonly INTERACTIVE_BROWSER_BLOCKLIST=(
    "Google Chrome.app/Contents/"
    "Safari.app/Contents/"
    "Firefox.app/Contents/"
    "Brave Browser.app/Contents/"
    "Microsoft Edge.app/Contents/"
    "Arc.app/Contents/"
    "Dia.app/Contents/"
)

# =============================================================================
# COLOR HELPERS (only when stdout is a TTY)
# =============================================================================
if [ -t 1 ]; then
    C_RED=$'\033[0;31m'
    C_GREEN=$'\033[0;32m'
    C_YELLOW=$'\033[0;33m'
    C_BLUE=$'\033[0;34m'
    C_DIM=$'\033[0;90m'
    C_BOLD=$'\033[1m'
    C_RESET=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_DIM=""; C_BOLD=""; C_RESET=""
fi
readonly C_RED C_GREEN C_YELLOW C_BLUE C_DIM C_BOLD C_RESET

# =============================================================================
# LOGGING
# =============================================================================
mkdir -p "$CONFIG_DIR" "$LOG_DIR"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG_FILE"; }
err() { echo "${C_RED}error:${C_RESET} $*" >&2; }
warn() { echo "${C_YELLOW}warn:${C_RESET}  $*" >&2; }

# =============================================================================
# HARD SAFETY (applied to every rule)
# =============================================================================

# Refuse to run as root. reap operates on the invoking user's own processes;
# root is neither needed nor safe.
require_nonroot() {
    if [ "$(id -u)" = "0" ]; then
        err "reap must not be run as root."
        err "It operates on your own user's processes. Run it as yourself."
        exit 1
    fi
}

# Refuse dangerously broad patterns.
is_pattern_safe() {
    local p="$1"
    [ -z "${p// /}" ] && return 1
    case "$p" in
        "*"|".*"|"."|".+"|".?"|".**") return 1 ;;
    esac
    [ ${#p} -lt 4 ] && return 1
    return 0
}

# Small process-query seams keep the classifier testable without touching real
# processes. They also centralize macOS ps formatting quirks.
process_command() {
    ps -p "$1" -o command= 2>/dev/null || true
}

process_activity_row() {
    ps -p "$1" -o ppid=,pgid=,tty= 2>/dev/null || true
}

has_live_child() {
    pgrep -P "$1" >/dev/null 2>&1
}

hard_block_reason() {
    local pid="$1"
    local cmd
    cmd=$(process_command "$pid")
    if [ -z "$cmd" ]; then
        echo "process no longer exists"
        return 0
    fi

    local block
    for block in "${BLOCKLIST[@]}"; do
        case "$cmd" in
            *"$block"*)
                echo "system or shell safety blocklist"
                return 0
                ;;
        esac
    done
    for block in "${INTERACTIVE_BROWSER_BLOCKLIST[@]}"; do
        case "$cmd" in
            *"$block"*)
                echo "interactive browser; calls, tabs, and screen sharing are protected"
                return 0
                ;;
        esac
    done
    return 1
}

is_blocked() {
    hard_block_reason "$1" >/dev/null
}

is_agent_host() {
    local cmd="$1" host
    for host in ${HOSTS[@]+"${HOSTS[@]}"}; do
        [[ "$cmd" =~ $host ]] && return 0
    done
    return 1
}

# A process has a live owner when it or any living ancestor still owns a TTY,
# or when a living ancestor is an agent host from HOSTS (GUI wrappers such as
# T3 Code run their agents without a TTY). This protects active sessions and
# every MCP, browser, or worker they spawned, including workers that created
# their own process group and therefore show tty=?? themselves. Leaks under a
# live host are the HOSTS tier's job, not the detached tiers'.
live_owner_reason() {
    local current="$1"
    local hops=0
    local row ppid _pgid tty
    while [ "$current" -gt 1 ] 2>/dev/null && [ "$hops" -lt 32 ]; do
        row=$(process_activity_row "$current")
        [ -z "$row" ] && return 1
        read -r ppid _pgid tty <<< "$row"
        if [ -n "${tty:-}" ] && [ "$tty" != "??" ] && [ "$tty" != "-" ]; then
            echo "owned by live terminal $tty"
            return 0
        fi
        if [ "$hops" -gt 0 ] && is_agent_host "$(process_command "$current")"; then
            echo "owned by live agent host PID $current"
            return 0
        fi
        case "${ppid:-}" in
            ""|*[!0-9]*) return 1 ;;
        esac
        [ "$ppid" = "$current" ] && return 1
        current="$ppid"
        hops=$((hops + 1))
    done
    return 1
}

is_agent_browser_daemon() {
    local cmd="$1"
    case "$cmd" in
        *"/agent-browser/bin/agent-browser-"*|*"agent-browser daemon"*) return 0 ;;
    esac
    return 1
}

candidate_signature() {
    ps -p "$1" -o lstart=,command= 2>/dev/null | cksum | awk '{print $1 ":" $2}'
}

CURRENT_CANDIDATES_FILE=""
CLASSIFICATION_REPORT_FILE=""

begin_classification_report() {
    CLASSIFICATION_REPORT_FILE=$(mktemp "${TMPDIR:-/tmp}/reap-report.XXXXXX")
}

classification_count() {
    local status="$1"
    [ -n "$CLASSIFICATION_REPORT_FILE" ] || {
        echo 0
        return
    }
    awk -F '\t' -v wanted="$status" \
        '$1 == wanted && !seen[$2]++ {count++} END {print count+0}' \
        "$CLASSIFICATION_REPORT_FILE"
}

finish_classification_report() {
    [ -n "$CLASSIFICATION_REPORT_FILE" ] \
        && rm -f "$CLASSIFICATION_REPORT_FILE"
    CLASSIFICATION_REPORT_FILE=""
}

begin_candidate_scan() {
    mkdir -p "$LOG_DIR"
    touch "$CANDIDATE_STATE_FILE"
    CURRENT_CANDIDATES_FILE=$(mktemp "${TMPDIR:-/tmp}/reap-candidates.XXXXXX")
}

finish_candidate_scan() {
    [ -z "$CURRENT_CANDIDATES_FILE" ] && return 0
    if [ -s "$CURRENT_CANDIDATES_FILE" ]; then
        awk -F '\t' 'NR==FNR {seen[$1]=1; next} ($1 in seen)' \
            "$CURRENT_CANDIDATES_FILE" "$CANDIDATE_STATE_FILE" \
            > "$CANDIDATE_STATE_FILE.tmp"
        mv "$CANDIDATE_STATE_FILE.tmp" "$CANDIDATE_STATE_FILE"
    else
        : > "$CANDIDATE_STATE_FILE"
    fi
    rm -f "$CURRENT_CANDIDATES_FILE"
    CURRENT_CANDIDATES_FILE=""
}

candidate_first_seen() {
    local signature="$1"
    [ -f "$CANDIDATE_STATE_FILE" ] || return 0
    awk -F '\t' -v sig="$signature" '$1 == sig {print $2; exit}' "$CANDIDATE_STATE_FILE"
}

remember_candidate() {
    local signature="$1"
    local first_seen="$2"
    grep -Fq "${signature}"$'\t' "$CANDIDATE_STATE_FILE" 2>/dev/null \
        || printf '%s\t%s\n' "$signature" "$first_seen" >> "$CANDIDATE_STATE_FILE"
    [ -n "$CURRENT_CANDIDATES_FILE" ] \
        && printf '%s\n' "$signature" >> "$CURRENT_CANDIDATES_FILE"
}

# Prints one of:
#   kill<TAB>reason
#   protected<TAB>reason
#   quarantine<TAB>reason
#
# A detached match must remain detached across scheduled scans before it can
# be killed. One old process is not proof of abandonment; repeated detached
# observations are.
classify_candidate() {
    local pid="$1"
    local mode="$2"
    local reason cmd signature first_seen now elapsed grace_seconds remaining

    if [ "$pid" = "$$" ] || [ "$pid" = "$PPID" ]; then
        printf 'protected\tReaper process tree\n'
        return
    fi
    if reason=$(hard_block_reason "$pid"); then
        printf 'protected\t%s\n' "$reason"
        return
    fi
    # Surplus duplicates under a live host are not detached, so quarantine and
    # owner protection do not apply. The group shape is the evidence.
    if [ "$mode" = "host" ]; then
        printf 'kill\tsurplus duplicate under a live agent host\n'
        return
    fi
    if reason=$(live_owner_reason "$pid"); then
        printf 'protected\t%s\n' "$reason"
        return
    fi

    cmd=$(process_command "$pid")
    if is_agent_browser_daemon "$cmd" && has_live_child "$pid"; then
        printf 'protected\tagent-browser session has a live browser child\n'
        return
    fi

    if [ "$mode" = "always" ]; then
        printf 'kill\texplicit ALWAYS_KILL rule and no active owner\n'
        return
    fi

    signature=$(candidate_signature "$pid")
    if [ -z "$signature" ]; then
        printf 'protected\tprocess no longer exists\n'
        return
    fi

    now=$(date +%s)
    first_seen=$(candidate_first_seen "$signature")
    grace_seconds=$((DETACHED_GRACE_MINUTES * 60))
    if [ -z "$first_seen" ]; then
        if [ "${DRY_RUN:-0}" != "1" ]; then
            remember_candidate "$signature" "$now"
        fi
        printf 'quarantine\tnew detached candidate; requires %sm continuous observation\n' \
            "$DETACHED_GRACE_MINUTES"
        return
    fi

    elapsed=$((now - first_seen))
    if [ "$elapsed" -lt "$grace_seconds" ]; then
        if [ "${DRY_RUN:-0}" != "1" ]; then
            remember_candidate "$signature" "$first_seen"
        fi
        remaining=$(((grace_seconds - elapsed + 59) / 60))
        printf 'quarantine\tdetached candidate; %sm quarantine remaining\n' "$remaining"
        return
    fi

    printf 'kill\tdetached for at least %sm across repeated scans\n' \
        "$DETACHED_GRACE_MINUTES"
}

# Filter a list of PIDs through hard safety, live-ownership checks, and the
# repeated-observation quarantine. Only kill-ready PIDs are printed to stdout.
sanitize_pids() {
    local mode="$1"
    shift
    local input="$*"
    local pid decision status reason
    local kept_pids=()
    for pid in $input; do
        decision=$(classify_candidate "$pid" "$mode")
        status="${decision%%$'\t'*}"
        reason="${decision#*$'\t'}"
        if [ -n "$CLASSIFICATION_REPORT_FILE" ]; then
            printf '%s\t%s\t%s\n' "$status" "$pid" "$reason" \
                >> "$CLASSIFICATION_REPORT_FILE"
        fi
        if [ "$status" = "kill" ]; then
            kept_pids+=("$pid")
        elif [ "${DRY_RUN:-0}" = "1" ] || [ "${VERBOSE:-0}" = "1" ]; then
            printf "  ${C_DIM}%-11s PID %-6s %s${C_RESET}\n" \
                "$status" "$pid" "$reason" >&2
        fi
    done
    echo "${kept_pids[*]:-}"
}

# =============================================================================
# CONFIG LOADING
# =============================================================================
load_config() {
    ALWAYS_KILL=()
    ORPHAN_ONLY=(
        "claude --output-format stream-json"
        "cursor-agent.*stream"
        "codex.*--output-format"
        "aider.*--stream"
        "codex app-server --listen stdio"
        "bun .*/\\.bun/bin/omp"
        "__omp_worker_"
        # MCP servers spawned by AI IDEs. They're almost always children of
        # the IDE, so they become orphans the moment the IDE dies.
        "node.*mcp-server-"
        "node.*@modelcontextprotocol/server-"
    )
    OLD_PROCESS=(
        "ms-playwright/chromium"
        "puppeteer.*chromium"
        "chrome-headless-shell"
        "agent-browser/bin/agent-browser-"
        "mcp-remote"
        "shadcn mcp"
        "@modelcontextprotocol/server-"
        "node.*mcp-server-"
        "convex.*mcp start"
        "bun .*/\\.bun/bin/omp"
        "__omp_worker_"
    )
    OLD_THRESHOLD_HOURS=2

    # HEAVY_MEMORY: opt-in tier for detached processes whose RSS exceeds
    # HEAVY_MEMORY_MB. Live terminal ownership and interactive browsers remain
    # protected even when a user opts into a broad resource pattern.
    HEAVY_MEMORY=()
    HEAVY_MEMORY_MB=2000

    # HIGH_CPU: opt-in tier for detached processes whose %CPU stays above
    # HIGH_CPU_PCT across two samples taken HIGH_CPU_SAMPLE_SEC apart.
    # Live terminal ownership and interactive browsers remain protected.
    HIGH_CPU=()
    HIGH_CPU_PCT=85
    HIGH_CPU_SAMPLE_SEC=20

    # DEDUPE: opt-in tier that keeps only the N newest instances of each
    # pattern, killing the rest. Built for the MCP-server-hoarding case:
    # every claude/cursor-agent/codex session spawns its own MCPs (posthog,
    # shadcn, @modelcontextprotocol/server-*); when the session dies they
    # often persist parented to a long-lived npx wrapper, so PPID=1
    # detection misses them. They idle at 0% CPU with low RAM each, but
    # accumulate to hundreds of MB across dozens of leaked instances.
    #
    # Empty by default. DEDUPE_KEEP must be >= 1 (safety: never zero a
    # pattern). All other safety guards still apply.
    DEDUPE=()
    DEDUPE_KEEP=3

    # HOSTS: long-lived agent hosts whose direct children leak while the host
    # stays alive. Codex app-server starts a full MCP set per thread and
    # subagent and never stops it; under T3 Code that reached 116 sets and
    # 35 GB overnight. For each host, children are grouped by command and the
    # HOST_CHILDREN_KEEP newest per group survive; older surplus children past
    # HOST_CHILDREN_MIN_AGE_MIN are reaped with their subtrees. Hosts also
    # count as live owners, so the detached tiers leave their trees alone.
    # 20/15 replayed against a heavy T3 subagent night cut no live session
    # and capped the leak at about 20 sets; 6/30 cut 6 live sessions.
    HOSTS=(
        "codex app-server"
        "claude --output-format stream-json"
    )
    HOST_CHILDREN_KEEP=20
    HOST_CHILDREN_MIN_AGE_MIN=15

    # Memory guard: above SWAP_ALERT_MB of used swap, log and notify with the
    # heaviest process trees. Above SWAP_CRITICAL_MB, the HOSTS tier runs with
    # half the keep, a 5 minute age floor, and no batch cap for that run.
    SWAP_ALERT_MB=8192
    SWAP_CRITICAL_MB=12288
    RULE_KILL_CAP=$MAX_KILLS_PER_RULE

    # WORKTREE_ROOTS: opt-in disk cleanup. Agent wrappers create a git
    # worktree per thread or subagent and never remove it; each one carries
    # its own node_modules and build cache (about 1.6 GB for a Next.js app).
    # Under these roots, linked worktrees that are clean, idle for
    # WORKTREE_IDLE_DAYS and not in use get their WORKTREE_DEPENDENCY_DIRS
    # moved to the Trash once every WORKTREE_SCAN_HOURS. Code, commits and
    # uncommitted work are never touched; an install brings them back.
    WORKTREE_ROOTS=()
    WORKTREE_IDLE_DAYS=3
    WORKTREE_DEPENDENCY_DIRS=(node_modules .next)
    WORKTREE_SCAN_HOURS=24
    WORKTREE_NOTIFY_GB=1

    # Sweep interval (seconds). install.sh substitutes this into the
    # LaunchAgent plist on `reap install`. Default 600 (10 min) for
    # protective coverage; raise if you want fewer runs.
    REAP_INTERVAL_SEC=600

    # A match must remain detached across repeated scheduled scans before it
    # becomes killable. This is the core distinction between an old process
    # and a process that has demonstrably lost its owner.
    DETACHED_GRACE_MINUTES=15

    # Graceful shutdown first; SIGKILL is only used for survivors.
    TERM_GRACE_SEC=3

    VERBOSE=0

    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    fi

    case "$DETACHED_GRACE_MINUTES" in
        ""|*[!0-9]*) DETACHED_GRACE_MINUTES=15 ;;
    esac
    case "$TERM_GRACE_SEC" in
        ""|*[!0-9]*) TERM_GRACE_SEC=3 ;;
    esac
    case "$HOST_CHILDREN_KEEP" in
        ""|*[!0-9]*|0) HOST_CHILDREN_KEEP=20 ;;
    esac
    case "$HOST_CHILDREN_MIN_AGE_MIN" in
        ""|*[!0-9]*) HOST_CHILDREN_MIN_AGE_MIN=15 ;;
    esac
    case "$WORKTREE_IDLE_DAYS" in
        ""|*[!0-9]*|0) WORKTREE_IDLE_DAYS=3 ;;
    esac
    case "$WORKTREE_SCAN_HOURS" in
        ""|*[!0-9]*) WORKTREE_SCAN_HOURS=24 ;;
    esac
    case "$WORKTREE_NOTIFY_GB" in
        ""|*[!0-9]*) WORKTREE_NOTIFY_GB=1 ;;
    esac
}

# =============================================================================
# CORE: pattern matchers (return PIDs on stdout, one per line)
# =============================================================================

match_always() {
    local pattern="$1"
    pgrep -U "$(id -u)" -f "$pattern" 2>/dev/null
}

match_orphan() {
    local pattern="$1"
    ps -U "$(id -u)" -o pid,ppid,command | \
        awk -v pat="$pattern" '$2==1 && $0 ~ pat {print $1}'
}

match_stale() {
    local pattern="$1"
    local thresh="$2"
    ps -U "$(id -u)" -o pid,etime,command | \
        awk -v pat="$pattern" -v thresh="$thresh" '
            $0 ~ pat {
                split($2, t, "-")
                if (length(t) == 2) { days = t[1]; rest = t[2] } else { days = 0; rest = t[1] }
                split(rest, hms, ":")
                if (length(hms) == 3) { h = hms[1] } else { h = 0 }
                if (days >= 1 || h >= thresh) print $1
            }
        '
}

# match_heavy: pattern matches AND rss (KB) >= threshold (MB * 1024).
# Independent of PPID — this tier catches active memory hogs that haven't
# been orphaned yet. Still constrained by the hard blocklist and the
# per-rule max-kill cap, same as every other tier.
match_heavy() {
    local pattern="$1"
    local mb="$2"
    local kb=$((mb * 1024))
    ps -U "$(id -u)" -o pid,rss,command | \
        awk -v pat="$pattern" -v kb="$kb" 'NR>1 && $0 ~ pat && $2+0 >= kb {print $1}'
}

# HIGH_CPU sampling state. Populated by prepare_cpu_samples() so all
# HIGH_CPU patterns share the same sample data and the wait happens once
# per run rather than once per pattern.
CPU_SAMPLE_1=""
CPU_SAMPLE_2=""

prepare_cpu_samples() {
    [ ${#HIGH_CPU[@]} -eq 0 ] && return 0
    [ -n "$CPU_SAMPLE_1" ] && return 0   # already sampled this run
    CPU_SAMPLE_1=$(mktemp)
    CPU_SAMPLE_2=$(mktemp)
    if [ -t 1 ] && [ "${HIGH_CPU_QUIET:-0}" != "1" ]; then
        printf "%s" "${C_DIM}sampling CPU for HIGH_CPU tier (~${HIGH_CPU_SAMPLE_SEC}s)...${C_RESET} "
    fi
    ps -U "$(id -u)" -o pid,%cpu,command > "$CPU_SAMPLE_1"
    sleep "$HIGH_CPU_SAMPLE_SEC"
    ps -U "$(id -u)" -o pid,%cpu,command > "$CPU_SAMPLE_2"
    if [ -t 1 ] && [ "${HIGH_CPU_QUIET:-0}" != "1" ]; then
        printf "%s\n" "${C_DIM}done${C_RESET}"
    fi
}

cleanup_cpu_samples() {
    [ -n "$CPU_SAMPLE_1" ] && rm -f "$CPU_SAMPLE_1" "$CPU_SAMPLE_2"
    CPU_SAMPLE_1=""
    CPU_SAMPLE_2=""
}

# match_high_cpu: pattern matches AND avg(%CPU) over two samples is at
# least the threshold. Uses cached samples from prepare_cpu_samples.
match_high_cpu() {
    local pattern="$1"
    local pct="$2"
    [ -z "$CPU_SAMPLE_1" ] && return 0
    awk -v pat="$pattern" -v thresh="$pct" '
        NR == FNR {
            if (FNR > 1 && $0 ~ pat) cpu1[$1] = $2
            next
        }
        FNR > 1 && $0 ~ pat && ($1 in cpu1) {
            avg = (cpu1[$1] + $2) / 2
            if (avg >= thresh) print $1
        }
    ' "$CPU_SAMPLE_1" "$CPU_SAMPLE_2"
}

# match_dedupe: list matching PIDs sorted by age (newest first), keep
# `keep` newest, return the rest as kill candidates. Solves duplicate-
# accumulation when something keeps spawning fresh instances of the
# same process and forgetting to clean up the old ones (looking at you,
# every MCP server pattern across every agent CLI).
match_dedupe() {
    local pattern="$1"
    local keep_count="$2"
    [ "$keep_count" -lt 1 ] 2>/dev/null && keep_count=1   # safety: never zero a pattern
    ps -U "$(id -u)" -o pid,etime,command 2>/dev/null | \
        awk -v pat="$pattern" '
            NR > 1 && $0 ~ pat {
                n = split($2, t, "-")
                if (n == 2) { d = t[1]; rest = t[2] } else { d = 0; rest = t[1] }
                split(rest, hms, ":")
                if (length(hms) == 3) secs = hms[1]*3600 + hms[2]*60 + hms[3]
                else if (length(hms) == 2) secs = hms[1]*60 + hms[2]
                else secs = hms[1]
                printf "%d %s\n", d*86400 + secs, $1
            }
        ' | sort -n | tail -n +"$((keep_count + 1))" | sort -rn | awk '{print $2}'
}

# Process table seam: "pid ppid etime command" for the invoking user.
process_table() {
    ps -U "$(id -u)" -o pid=,ppid=,etime=,command= 2>/dev/null
}

# match_host_children: for each live process matching the host pattern, group
# its direct children by command (digits normalized), keep the `keep` newest
# per group, and print older surplus children past `min_age_min`, oldest first.
match_host_children() {
    local pattern="$1"
    local keep_count="$2"
    local min_age_sec=$(($3 * 60))
    [ "$keep_count" -lt 1 ] 2>/dev/null && keep_count=1   # safety: never zero a group
    process_table | awk -v pat="$pattern" '
        {
            n = split($3, t, "-")
            if (n == 2) { d = t[1]; rest = t[2] } else { d = 0; rest = t[1] }
            m = split(rest, hms, ":")
            if (m == 3) secs = hms[1]*3600 + hms[2]*60 + hms[3]
            else if (m == 2) secs = hms[1]*60 + hms[2]
            else secs = hms[1]
            cmd = $0
            sub(/^ *[0-9]+ +[0-9]+ +[^ ]+ +/, "", cmd)
            pid[NR] = $1; parent[NR] = $2; age[NR] = d*86400 + secs; command[NR] = cmd
            if (cmd ~ pat) host[$1] = 1
        }
        END {
            for (i = 1; i <= NR; i++) {
                if (!(parent[i] in host)) continue
                key = command[i]
                gsub(/[0-9]+/, "#", key)
                printf "%s %s\t%d\t%s\n", parent[i], key, age[i], pid[i]
            }
        }
    ' | sort -t $'\t' -k1,1 -k2,2n | awk -F '\t' -v keep="$keep_count" -v min_age="$min_age_sec" '
        $1 != group { group = $1; seen = 0 }
        { seen++ }
        seen > keep && $2 >= min_age { print $2, $3 }
    ' | sort -rn | awk '{print $2}'
}

# Expand kill-ready roots with their living descendants so a reaped host or
# MCP wrapper does not leave grandchildren to reparent to launchd. The hard
# blocklist still applies to every descendant.
with_descendants() {
    [ -z "$*" ] && return 0
    local pid out=()
    for pid in $(process_table | awk -v roots=" $* " '
        { parent[$1] = $2 }
        END {
            n = split(roots, r, " ")
            for (i = 1; i <= n; i++) tree[r[i]] = 1
            do {
                grew = 0
                for (p in parent) if (!(p in tree) && (parent[p] in tree)) { tree[p] = 1; grew = 1 }
            } while (grew)
            for (p in tree) print p
        }' | sort -n); do
        is_blocked "$pid" || out+=("$pid")
    done
    echo "${out[*]:-}"
}

# =============================================================================
# CORE: per-rule execution
# =============================================================================

format_pid_row() {
    local pid="$1"
    local info
    info=$(ps -p "$pid" -o etime=,command= 2>/dev/null)
    [ -z "$info" ] && return
    local age cmd
    age=$(echo "$info" | awk '{print $1}')
    cmd=$(echo "$info" | awk '{$1=""; print}' | sed 's/^ //' | cut -c1-72)
    printf "    ${C_DIM}PID %-6s  %-12s${C_RESET}  %s\n" "$pid" "$age" "$cmd"
}

terminate_pids() {
    local pids="$*"
    [ -z "$pids" ] && return 0

    # SIGTERM lets MCP servers, browser daemons, and Node wrappers release
    # sockets and child processes cleanly. SIGKILL is a bounded fallback only.
    # shellcheck disable=SC2086
    kill -TERM $pids 2>/dev/null || true
    sleep "$TERM_GRACE_SEC"

    local pid
    local survivors=()
    for pid in $pids; do
        if kill -0 "$pid" 2>/dev/null; then
            survivors+=("$pid")
        fi
    done
    if [ "${#survivors[@]}" -gt 0 ]; then
        kill -KILL "${survivors[@]}" 2>/dev/null || true
        log "Escalated ${#survivors[@]} stubborn process(es) to SIGKILL. PIDs: ${survivors[*]}"
    fi
}

process_rule() {
    local mode="$1"
    local pattern="$2"
    local thresh="${3:-}"

    if ! is_pattern_safe "$pattern"; then
        warn "skipping unsafe pattern: '$pattern' (too broad or too short)"
        return
    fi

    local pids_raw
    case "$mode" in
        always) pids_raw=$(match_always "$pattern") ;;
        orphan) pids_raw=$(match_orphan "$pattern") ;;
        stale)  pids_raw=$(match_stale  "$pattern" "$thresh") ;;
        heavy)  pids_raw=$(match_heavy  "$pattern" "$thresh") ;;
        cpu)    pids_raw=$(match_high_cpu "$pattern" "$thresh") ;;
        dedupe) pids_raw=$(match_dedupe "$pattern" "$thresh") ;;
        host)   pids_raw=$(match_host_children "$pattern" "$thresh" "$HOST_CHILDREN_MIN_AGE_MIN") ;;
    esac

    local pids
    pids=$(sanitize_pids "$mode" "$pids_raw")
    [ -z "$pids" ] && return

    local count
    count=$(echo "$pids" | wc -w | tr -d ' ')
    if [ "$count" -gt "$RULE_KILL_CAP" ]; then
        case "$mode" in
            dedupe|host)
                # Surplus duplicates arrive oldest first. Reap a capped batch
                # so a large leak drains across runs instead of aborting forever.
                # shellcheck disable=SC2086
                pids=$(printf '%s\n' $pids | head -n "$RULE_KILL_CAP" | tr '\n' ' ')
                log "Capped rule '$pattern' ($mode): $count matches, reaping oldest $RULE_KILL_CAP"
                count=$RULE_KILL_CAP
                ;;
            *)
                warn "rule '$pattern' ($mode) matched $count processes (>$RULE_KILL_CAP cap)"
                warn "aborting this rule. Review manually, something looks off"
                log "ABORTED rule '$pattern' ($mode): $count matches exceeds cap"
                return
                ;;
        esac
    fi

    local targets extra
    # shellcheck disable=SC2086
    targets=$(with_descendants $pids)
    extra=$(( $(echo "$targets" | wc -w) - count ))
    [ "$extra" -lt 0 ] && extra=0

    local label
    case "$mode" in
        always) label="always" ;;
        orphan) label="orphan (PPID=1)" ;;
        stale)  label="stale (>${thresh}h)" ;;
        heavy)  label="heavy (>${thresh}MB RSS)" ;;
        cpu)    label="cpu (>${thresh}% sustained)" ;;
        dedupe) label="dedupe (keep ${thresh} newest)" ;;
        host)   label="host surplus (keep ${thresh} newest per command)" ;;
    esac

    if [ "$DRY_RUN" = "1" ]; then
        echo ""
        echo "${C_YELLOW}would kill${C_RESET} ${C_BOLD}$count${C_RESET} process(es) ${C_DIM}+$extra descendant(s), $label: $pattern${C_RESET}"
        local pid
        for pid in $pids; do format_pid_row "$pid"; done
        DRY_TOTAL=$((DRY_TOTAL + count))
    else
        terminate_pids "$targets"
        log "Terminated $count ($label: $pattern). PIDs: $pids (+$extra descendants)"
        if [ "$VERBOSE" = "1" ]; then
            echo "${C_RED}terminated${C_RESET} $count, ${C_DIM}$label: $pattern${C_RESET}"
        fi
        KILL_TOTAL=$((KILL_TOTAL + count))
    fi
}

process_all_rules() {
    # Take the two CPU samples up-front (cached for the run). No-op if
    # HIGH_CPU is empty.
    prepare_cpu_samples

    local p
    for p in ${ALWAYS_KILL[@]+"${ALWAYS_KILL[@]}"};   do process_rule always "$p"; done
    for p in ${ORPHAN_ONLY[@]+"${ORPHAN_ONLY[@]}"};   do process_rule orphan "$p"; done
    for p in ${HOSTS[@]+"${HOSTS[@]}"};               do process_rule host   "$p" "$HOST_CHILDREN_KEEP"; done
    for p in ${OLD_PROCESS[@]+"${OLD_PROCESS[@]}"};   do process_rule stale  "$p" "$OLD_THRESHOLD_HOURS"; done
    for p in ${HEAVY_MEMORY[@]+"${HEAVY_MEMORY[@]}"}; do process_rule heavy  "$p" "$HEAVY_MEMORY_MB"; done
    for p in ${HIGH_CPU[@]+"${HIGH_CPU[@]}"};         do process_rule cpu    "$p" "$HIGH_CPU_PCT"; done
    for p in ${DEDUPE[@]+"${DEDUPE[@]}"};             do process_rule dedupe "$p" "$DEDUPE_KEEP"; done

    cleanup_cpu_samples
}

# =============================================================================
# MEMORY GUARD
# =============================================================================

swap_used_mb() {
    sysctl -n vm.swapusage 2>/dev/null | awk '{
        for (i = 1; i < NF; i++) if ($i == "used") {
            v = $(i + 2); u = substr(v, length(v)); n = substr(v, 1, length(v) - 1) + 0
            if (u == "G") n *= 1024
            printf "%d\n", n
            exit
        }
    }'
}

# Heaviest process trees by footprint, as "T3 Code 30.1G via codex, Name 2.0G".
# top's MEM counts compressed and swapped pages; ps RSS misses them exactly
# when it matters. Each process is charged to its top ancestor below launchd;
# "via" names the deepest descendant whose subtree still holds most of it.
top_memory_trees() {
    {
        top -l 1 -o mem -n 2000 -stats pid,mem 2>/dev/null | awk '$1 ~ /^[0-9]+$/ {print "M", $1, $2}'
        ps -axo pid=,ppid=,comm= | awk '{print "P", $0}'
    } | awk '
        $1 == "M" {
            v = $3; gsub(/[+-]/, "", v); u = substr(v, length(v)); n = substr(v, 1, length(v) - 1) + 0
            if (u == "G") n *= 1024; else if (u == "K") n /= 1024; else if (u == "B") n /= 1048576
            mem[$2] = n
            next
        }
        $1 == "P" {
            parent[$2] = $3
            kids[$3] = kids[$3] " " $2
            c = $0; sub(/^P +[0-9]+ +[0-9]+ +/, "", c); sub(/.*\//, "", c)
            name[$2] = c
        }
        END {
            for (p in mem) {
                r = p; hops = 0
                total[r] += mem[p]
                while ((r in parent) && parent[r] > 1 && hops < 64) { r = parent[r]; total[r] += mem[p]; hops++ }
                root[r] = 1
            }
            for (r in root) {
                cur = r
                for (depth = 0; depth < 64; depth++) {
                    n = split(kids[cur], k, " "); best = ""; bestv = 0
                    for (i = 1; i <= n; i++) if (total[k[i]] > bestv) { bestv = total[k[i]]; best = k[i] }
                    if (best == "" || bestv < total[r] / 2) break
                    cur = best
                }
                printf "%d\t%s\t%s\n", total[r], name[r], (cur != r ? name[cur] : "")
            }
        }
    ' | sort -rn | head -n 3 | awk -F '\t' '{
        printf "%s%s %.1fG%s", sep, $2, $1 / 1024, ($3 != "" && $3 != $2 ? " via " $3 : ""); sep = ", "
    }'
}

notify_memory() {
    local level="$1" message="$2"
    local stamp="$LOG_DIR/last-memory-$level"
    [ -n "$(find "$stamp" -mmin -60 2>/dev/null)" ] && return 0
    touch "$stamp"
    osascript -e "display notification \"${message//\"/}\" with title \"Agent Reaper\" subtitle \"Memory $level\"" \
        >/dev/null 2>&1 || true
}

# Runs once per scheduled sweep, before the rules. Above SWAP_ALERT_MB it logs
# and notifies (at most hourly per level) with the heaviest trees. Above
# SWAP_CRITICAL_MB it also tightens the HOSTS tier for this run.
memory_guard() {
    local used trees
    used=$(swap_used_mb)
    case "$used" in ""|*[!0-9]*) return 0 ;; esac
    [ "$used" -ge "$SWAP_ALERT_MB" ] || return 0

    trees=$(top_memory_trees)
    if [ "$used" -ge "$SWAP_CRITICAL_MB" ]; then
        HOST_CHILDREN_KEEP=$(( (HOST_CHILDREN_KEEP + 1) / 2 ))
        HOST_CHILDREN_MIN_AGE_MIN=5
        RULE_KILL_CAP=100000
        log "Memory CRITICAL: swap ${used}MB used, HOSTS tier tightened for this run. Heaviest: $trees"
        notify_memory critical "Swap at $((used / 1024)) GB. Reaping surplus agent children. Heaviest: $trees"
    else
        log "Memory alert: swap ${used}MB used. Heaviest: $trees"
        notify_memory alert "Swap at $((used / 1024)) GB. Heaviest: $trees"
    fi
}

# =============================================================================
# DISK: dependency folders of idle agent worktrees
# =============================================================================

readonly WORKTREE_STATE_FILE="$LOG_DIR/worktrees-last-scan"
readonly WORKTREE_HISTORY_FILE="$LOG_DIR/worktrees.tsv"

# A dependency dir name must be a plain folder name. Anything with a slash,
# a dot-only name or .git is refused, whatever the config says.
is_dependency_name_safe() {
    case "$1" in
        ""|.|..|.git|*/*) return 1 ;;
    esac
    return 0
}

# Linked worktrees under the configured roots, one per line. A linked worktree
# has a .git *file* pointing at the main repository; main checkouts have a
# .git directory and are never considered. Dependency folders are pruned so
# the walk stays shallow and fast.
list_worktrees() {
    local root
    for root in ${WORKTREE_ROOTS[@]+"${WORKTREE_ROOTS[@]}"}; do
        root="${root%/}"
        [ -d "$root" ] || continue
        case "$root" in "$HOME"|"$HOME"/|/|/Users|/System*|/Library*) continue ;; esac
        find "$root" -mindepth 2 -maxdepth 5 \
            \( -name node_modules -o -name .next -o -name .venv -o -name target \) -prune \
            -o -name .git -type f -print 2>/dev/null
    done | sed 's#/\.git$##' | sort -u
}

# Epoch seconds of the last git activity in a worktree: the newest of its
# index, HEAD and HEAD reflog inside the worktree's own git dir.
worktree_last_activity() {
    local wt="$1" gitdir newest=0 f m
    gitdir=$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null) || { echo 0; return; }
    for f in "$gitdir/index" "$gitdir/HEAD" "$gitdir/logs/HEAD"; do
        [ -e "$f" ] || continue
        m=$(stat -f %m "$f" 2>/dev/null || echo 0)
        [ "$m" -gt "$newest" ] && newest=$m
    done
    echo "$newest"
}

# Prints the reason a worktree must be left alone, or nothing when it is safe
# to clean. $2 is the snapshot of process cwds and command lines.
worktree_skip_reason() {
    local wt="$1" in_use="$2" last now
    now=$(date +%s)
    last=$(worktree_last_activity "$wt")
    if [ "$last" -gt 0 ] && [ $((now - last)) -lt $((WORKTREE_IDLE_DAYS * 86400)) ]; then
        echo "git activity in the last ${WORKTREE_IDLE_DAYS}d"
        return
    fi
    # lsof reports resolved paths (/private/var, not /var), so match both.
    local real
    real=$(cd "$wt" 2>/dev/null && pwd -P) || real="$wt"
    if grep -qF -e "$wt" -e "$real" <<< "$in_use"; then
        echo "a process is running inside it"
        return
    fi
    # --no-optional-locks: never rewrite the index, which would reset the idle clock.
    local status
    if ! status=$(git --no-optional-locks -C "$wt" status --porcelain 2>/dev/null); then
        echo "git status failed"
        return
    fi
    if [ -n "$status" ]; then
        echo "uncommitted changes"
        return
    fi
}

# Moves paths to the Trash (never deletes). Separate function so tests can
# replace it.
trash_paths() {
    /usr/bin/trash "$@" >/dev/null 2>&1
}

format_size_kb() {
    awk -v kb="$1" 'BEGIN {
        if (kb >= 1048576) printf "%.1f GB", kb / 1048576
        else printf "%d MB", kb / 1024
    }'
}

# Scans the roots. DRY_RUN=1 only reports. Sets DISK_TOTAL_KB and
# DISK_CLEANED for the caller.
process_worktrees() {
    DISK_TOTAL_KB=0
    DISK_CLEANED=0
    local skipped=0
    [ ${#WORKTREE_ROOTS[@]} -eq 0 ] && return 0

    if [ "$DRY_RUN" != "1" ] && [ ! -x /usr/bin/trash ]; then
        log "Worktrees: /usr/bin/trash not found (macOS 15+), skipping disk cleanup"
        return 0
    fi

    local in_use
    in_use=$( { lsof -nP -a -u "$(id -u)" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p'
                ps -U "$(id -u)" -o command= 2>/dev/null; } )

    local wt reason name kb targets
    while IFS= read -r wt; do
        [ -n "$wt" ] || continue
        targets=()
        for name in ${WORKTREE_DEPENDENCY_DIRS[@]+"${WORKTREE_DEPENDENCY_DIRS[@]}"}; do
            is_dependency_name_safe "$name" || continue
            [ -d "$wt/$name" ] && [ ! -L "$wt/$name" ] && targets+=("$wt/$name")
        done
        [ ${#targets[@]} -eq 0 ] && continue

        reason=$(worktree_skip_reason "$wt" "$in_use")
        if [ -n "$reason" ]; then
            skipped=$((skipped + 1))
            [ "$DRY_RUN" = "1" ] && printf "  ${C_DIM}keep        %s  %s${C_RESET}\n" "$wt" "$reason"
            continue
        fi

        kb=$(du -sk "${targets[@]}" 2>/dev/null | awk '{s += $1} END {print s + 0}')
        if [ "$DRY_RUN" = "1" ]; then
            printf "  ${C_YELLOW}trash${C_RESET}       %s  ${C_BOLD}%s${C_RESET}\n" "$wt" "$(format_size_kb "$kb")"
        else
            if ! trash_paths "${targets[@]}"; then
                log "Worktrees: could not move to Trash: ${targets[*]}"
                continue
            fi
            log "Worktrees: trashed $(format_size_kb "$kb") from $wt"
            printf '%s\t%s\t%s\n' "$(date +%Y-%m-%d)" "$kb" "$wt" >> "$WORKTREE_HISTORY_FILE"
        fi
        DISK_TOTAL_KB=$((DISK_TOTAL_KB + kb))
        DISK_CLEANED=$((DISK_CLEANED + 1))
    done < <(list_worktrees)

    if [ "$DRY_RUN" = "1" ]; then
        return 0
    fi
    date +%s > "$WORKTREE_STATE_FILE"
    log "Worktrees: $DISK_CLEANED cleaned, $(format_size_kb "$DISK_TOTAL_KB") moved to Trash, $skipped kept"
    if [ "$DISK_TOTAL_KB" -ge $((WORKTREE_NOTIFY_GB * 1048576)) ] && [ "$WORKTREE_NOTIFY_GB" -gt 0 ]; then
        osascript -e "display notification \"$(format_size_kb "$DISK_TOTAL_KB") of dependencies from $DISK_CLEANED idle worktree(s) moved to the Trash. Empty it to free the space.\" with title \"Agent Reaper\" subtitle \"Disk\"" \
            >/dev/null 2>&1 || true
    fi
}

# True when the scheduled disk scan is due.
worktree_scan_due() {
    [ ${#WORKTREE_ROOTS[@]} -gt 0 ] || return 1
    [ -f "$WORKTREE_STATE_FILE" ] || return 0
    local last now
    last=$(cat "$WORKTREE_STATE_FILE" 2>/dev/null)
    case "$last" in ""|*[!0-9]*) return 0 ;; esac
    now=$(date +%s)
    [ $((now - last)) -ge $((WORKTREE_SCAN_HOURS * 3600)) ]
}

# =============================================================================
# SUBCOMMANDS
# =============================================================================

cmd_run() {
    require_nonroot
    load_config
    DRY_RUN=0
    KILL_TOTAL=0
    begin_candidate_scan
    memory_guard
    process_all_rules
    finish_candidate_scan
    if worktree_scan_due; then
        process_worktrees
    fi

    if [ "$KILL_TOTAL" -eq 0 ]; then
        log "Clean run, no zombies found"
        [ "$VERBOSE" = "1" ] && echo "${C_GREEN}clean${C_RESET}, no zombies found"
    else
        log "=== Reaped $KILL_TOTAL process(es) ==="
        [ "$VERBOSE" = "1" ] && echo "${C_BOLD}reaped $KILL_TOTAL process(es)${C_RESET}"
    fi

    if [ -f "$LOG_FILE" ]; then
        tail -n 500 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
}

cmd_preview() {
    require_nonroot
    load_config
    DRY_RUN=1
    DRY_TOTAL=0
    begin_classification_report

    echo "${C_BLUE}${C_BOLD}reap preview${C_RESET} ${C_DIM}(dry-run, nothing will be killed)${C_RESET}"
    process_all_rules

    local protected_count quarantine_count
    protected_count=$(classification_count protected)
    quarantine_count=$(classification_count quarantine)
    finish_classification_report

    echo ""
    if [ "$DRY_TOTAL" -eq 0 ]; then
        if [ "$protected_count" -gt 0 ] || [ "$quarantine_count" -gt 0 ]; then
            echo "${C_GREEN}no kill-ready processes${C_RESET}  ${C_DIM}${quarantine_count} quarantined · ${protected_count} protected${C_RESET}"
        else
            echo "${C_GREEN}clean${C_RESET}, no processes match current rules"
        fi
    else
        echo "${C_BOLD}would reap $DRY_TOTAL process(es)${C_RESET}  ${C_DIM}${quarantine_count} quarantined · ${protected_count} protected${C_RESET}"
    fi

    if [ ${#WORKTREE_ROOTS[@]} -gt 0 ]; then
        echo ""
        disk_preview
    fi
}

disk_preview() {
    echo "${C_BLUE}${C_BOLD}worktrees${C_RESET} ${C_DIM}(dry-run, nothing will be moved; idle > ${WORKTREE_IDLE_DAYS}d, dirs: ${WORKTREE_DEPENDENCY_DIRS[*]})${C_RESET}"
    DRY_RUN=1
    process_worktrees
    if [ "$DISK_CLEANED" -eq 0 ]; then
        echo "${C_GREEN}nothing to clean${C_RESET}"
    else
        echo "${C_BOLD}would move $(format_size_kb "$DISK_TOTAL_KB") from $DISK_CLEANED worktree(s) to the Trash${C_RESET}"
    fi
}

# reap disk        dry-run of the worktree cleanup
# reap disk run    clean now, regardless of WORKTREE_SCAN_HOURS
cmd_disk() {
    require_nonroot
    load_config
    if [ ${#WORKTREE_ROOTS[@]} -eq 0 ]; then
        echo "disk cleanup is off. Set WORKTREE_ROOTS in $CONFIG_FILE (reap config)."
        return 0
    fi
    case "${1:-preview}" in
        preview|dry-run) disk_preview ;;
        run)
            DRY_RUN=0
            process_worktrees
            echo "${C_BOLD}moved $(format_size_kb "$DISK_TOTAL_KB") from $DISK_CLEANED worktree(s) to the Trash${C_RESET}"
            ;;
        *) err "usage: reap disk [run]"; return 2 ;;
    esac
}

cmd_status() {
    load_config

    echo "${C_BOLD}reap${C_RESET} ${C_DIM}v${REAP_VERSION}${C_RESET}"
    echo ""

    if launchctl list 2>/dev/null | grep -q "$REAP_LABEL"; then
        local interval_min=$((REAP_INTERVAL_SEC / 60))
        echo "${C_GREEN}●${C_RESET} scheduled    every ${interval_min} minutes via launchd"
    else
        echo "${C_YELLOW}○${C_RESET} not scheduled. Run '${C_BOLD}reap install${C_RESET}'"
    fi

    local a="${#ALWAYS_KILL[@]}" o="${#ORPHAN_ONLY[@]}" s="${#OLD_PROCESS[@]}" h="${#HEAVY_MEMORY[@]}" c="${#HIGH_CPU[@]}" d="${#DEDUPE[@]}" k="${#HOSTS[@]}"
    echo "${C_DIM}  config: $a always · $o orphan · $k hosts (keep ${HOST_CHILDREN_KEEP}) · $s stale (>${OLD_THRESHOLD_HOURS}h) · $h heavy (>${HEAVY_MEMORY_MB}MB) · $c cpu (>${HIGH_CPU_PCT}%) · $d dedupe (keep ${DEDUPE_KEEP})${C_RESET}"
    echo "${C_DIM}  memory: swap $(swap_used_mb)MB used · alert ${SWAP_ALERT_MB}MB · critical ${SWAP_CRITICAL_MB}MB${C_RESET}"
    if [ ${#WORKTREE_ROOTS[@]} -gt 0 ]; then
        echo "${C_DIM}  disk:   ${#WORKTREE_ROOTS[@]} worktree root(s) · idle > ${WORKTREE_IDLE_DAYS}d · every ${WORKTREE_SCAN_HOURS}h${C_RESET}"
    else
        echo "${C_DIM}  disk:   off (set WORKTREE_ROOTS to clean idle agent worktrees)${C_RESET}"
    fi

    if [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
        echo ""
        echo "${C_BOLD}recent activity${C_RESET}"
        tail -n 5 "$LOG_FILE" | while IFS= read -r line; do
            echo "  ${C_DIM}$line${C_RESET}"
        done
    fi

    echo ""
    echo "${C_DIM}commands: reap preview · reap top · reap run · reap disk · reap doctor · reap stats · reap logs · reap config${C_RESET}"
}

# cmd_top — list processes that match *any* configured rule, sorted by
# resident memory. No kills. Great for "what's about to get reaped?" and
# for demoing the HEAVY_MEMORY tier ("look at that 5GB zombie").
cmd_top() {
    require_nonroot
    load_config
    DRY_RUN=1

    echo "${C_BOLD}reap top${C_RESET} ${C_DIM}(candidates, ordered by RSS — nothing will be killed)${C_RESET}"
    echo ""

    # Collect "pid<TAB>tier<TAB>pattern" for every match. First match per
    # PID wins (process_all_rules evaluates in the same order, so this
    # lines up with what the next real run would actually do).
    local rows=""
    local pattern pid

    add_rows() {
        local mode="$1"; local pattern="$2"; local thresh="${3:-}"
        is_pattern_safe "$pattern" || return 0
        local pids_raw pids pid tier
        case "$mode" in
            always) pids_raw=$(match_always "$pattern");             tier="always" ;;
            orphan) pids_raw=$(match_orphan "$pattern");             tier="orphan" ;;
            stale)  pids_raw=$(match_stale  "$pattern" "$thresh");   tier="stale(>${thresh}h)" ;;
            heavy)  pids_raw=$(match_heavy  "$pattern" "$thresh");   tier="heavy(>${thresh}MB)" ;;
            cpu)    pids_raw=$(match_high_cpu "$pattern" "$thresh"); tier="cpu(>${thresh}%)" ;;
            dedupe) pids_raw=$(match_dedupe "$pattern" "$thresh");   tier="dedupe(keep ${thresh})" ;;
            host)   pids_raw=$(match_host_children "$pattern" "$thresh" "$HOST_CHILDREN_MIN_AGE_MIN"); tier="host(keep ${thresh})" ;;
        esac
        pids=$(sanitize_pids "$mode" "$pids_raw")
        for pid in $pids; do
            rows="${rows}${pid}"$'\t'"${tier}"$'\t'"${pattern}"$'\n'
        done
    }

    # Take CPU samples once if HIGH_CPU has any patterns. No-op otherwise.
    prepare_cpu_samples

    for pattern in ${ALWAYS_KILL[@]+"${ALWAYS_KILL[@]}"};   do add_rows always "$pattern"; done
    for pattern in ${ORPHAN_ONLY[@]+"${ORPHAN_ONLY[@]}"};   do add_rows orphan "$pattern"; done
    for pattern in ${HOSTS[@]+"${HOSTS[@]}"};               do add_rows host   "$pattern" "$HOST_CHILDREN_KEEP"; done
    for pattern in ${OLD_PROCESS[@]+"${OLD_PROCESS[@]}"};   do add_rows stale  "$pattern" "$OLD_THRESHOLD_HOURS"; done
    for pattern in ${HEAVY_MEMORY[@]+"${HEAVY_MEMORY[@]}"}; do add_rows heavy  "$pattern" "$HEAVY_MEMORY_MB"; done
    for pattern in ${HIGH_CPU[@]+"${HIGH_CPU[@]}"};         do add_rows cpu    "$pattern" "$HIGH_CPU_PCT"; done
    for pattern in ${DEDUPE[@]+"${DEDUPE[@]}"};             do add_rows dedupe "$pattern" "$DEDUPE_KEEP"; done

    cleanup_cpu_samples

    if [ -z "$rows" ]; then
        echo "${C_GREEN}clean${C_RESET}, no kill-ready processes; protected and quarantined matches are shown above"
        return
    fi

    # Dedup by pid, keep first occurrence.
    local unique
    unique=$(printf '%b' "$rows" | awk -F'\t' '!seen[$1]++')

    # Enrich with rss/cpu/age/cmd and sort by RSS desc.
    printf "  ${C_DIM}%-7s  %-8s  %-6s  %-10s  %-22s  %s${C_RESET}\n" \
        "PID" "RSS" "%CPU" "AGE" "TIER" "COMMAND"
    printf '%s\n' "$unique" | while IFS=$'\t' read -r pid tier _pattern; do
        [ -z "$pid" ] && continue
        local info rss pct age cmd
        info=$(ps -p "$pid" -o rss=,%cpu=,etime=,command= 2>/dev/null) || continue
        [ -z "$info" ] && continue
        rss=$(echo "$info" | awk '{print $1}')
        pct=$(echo "$info" | awk '{print $2}')
        age=$(echo "$info" | awk '{print $3}')
        cmd=$(echo "$info" | awk '{$1=$2=$3=""; sub(/^ +/, ""); print}' | cut -c1-52)
        printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$rss" "$pid" "$pct" "$age" "$tier" "$cmd"
    done | sort -rn | while IFS=$'\t' read -r rss pid pct age tier cmd; do
        [ -z "$rss" ] && continue
        local rss_h
        if   [ "$rss" -ge 1048576 ]; then rss_h=$(awk -v k="$rss" 'BEGIN{printf "%.1fG", k/1048576}')
        elif [ "$rss" -ge 1024 ];    then rss_h=$(awk -v k="$rss" 'BEGIN{printf "%dM", k/1024}')
        else                              rss_h="${rss}K"
        fi
        printf "  ${C_DIM}%-7s${C_RESET}  ${C_BOLD}%-8s${C_RESET}  %-6s  %-10s  %-22s  %s\n" \
            "$pid" "$rss_h" "$pct" "$age" "$tier" "$cmd"
    done

    echo ""
    local total
    total=$(printf '%s\n' "$unique" | awk 'NF>0' | wc -l | tr -d ' ')
    echo "${C_DIM}${total} match(es) · ${C_RESET}${C_BOLD}reap run${C_RESET}${C_DIM} to kill them, ${C_RESET}${C_BOLD}reap preview${C_RESET}${C_DIM} for grouped view${C_RESET}"
}

# cmd_doctor — all-in-one health check. Answers "is the reaper actually
# working?" without digging through launchctl, the log, and the filesystem.
cmd_doctor() {
    load_config

    local C_OK="${C_GREEN}✓${C_RESET}"
    local C_BAD="${C_RED}✗${C_RESET}"
    local C_WRN="${C_YELLOW}⚠${C_RESET}"

    local bad=0
    local warn=0

    local reap_bin
    reap_bin=$(command -v reap 2>/dev/null || echo "${BASH_SOURCE[0]}")

    echo "${C_BOLD}reap doctor${C_RESET}"
    echo ""

    # 1. reap binary
    printf "  %s  %-16s ${C_DIM}%s (v%s)${C_RESET}\n" \
        "$C_OK" "reap binary" "$reap_bin" "$REAP_VERSION"

    # 2. launch agent
    if launchctl list 2>/dev/null | grep -q "$REAP_LABEL"; then
        local last_exit
        last_exit=$(launchctl print "gui/$(id -u)/$REAP_LABEL" 2>/dev/null \
            | awk -F'=' '/last exit code/ {gsub(/[^0-9-]/,"",$2); print $2; exit}')
        [ -z "$last_exit" ] && last_exit="?"
        printf "  %s  %-16s ${C_DIM}loaded, last exit %s${C_RESET}\n" \
            "$C_OK" "launch agent" "$last_exit"
    else
        printf "  %s  %-16s ${C_RED}NOT LOADED${C_RESET} ${C_DIM}— run 'reap install'${C_RESET}\n" \
            "$C_BAD" "launch agent"
        bad=$((bad+1))
    fi

    # 3. plist
    local plist_path="$HOME/Library/LaunchAgents/$REAP_LABEL.plist"
    if [ -f "$plist_path" ]; then
        printf "  %s  %-16s ${C_DIM}%s${C_RESET}\n" \
            "$C_OK" "plist" "${plist_path/#$HOME/~}"
    else
        printf "  %s  %-16s ${C_RED}missing${C_RESET}\n" "$C_BAD" "plist"
        bad=$((bad+1))
    fi

    # 4. app bundle
    local app_exec="$HOME/Applications/Agent Reaper.app/Contents/MacOS/AgentReaper"
    if [ -x "$app_exec" ]; then
        printf "  %s  %-16s ${C_DIM}~/Applications/Agent Reaper.app${C_RESET}\n" \
            "$C_OK" "app bundle"
    else
        printf "  %s  %-16s ${C_RED}executable missing${C_RESET}\n" \
            "$C_BAD" "app bundle"
        bad=$((bad+1))
    fi

    # 5. config
    if [ -f "$CONFIG_FILE" ]; then
        local a=${#ALWAYS_KILL[@]} o=${#ORPHAN_ONLY[@]} s=${#OLD_PROCESS[@]} h=${#HEAVY_MEMORY[@]} c=${#HIGH_CPU[@]} d=${#DEDUPE[@]} k=${#HOSTS[@]}
        printf "  %s  %-16s ${C_DIM}%d always · %d orphan · %d hosts · %d stale · %d heavy · %d cpu · %d dedupe${C_RESET}\n" \
            "$C_OK" "config" "$a" "$o" "$k" "$s" "$h" "$c" "$d"
    else
        printf "  %s  %-16s ${C_RED}missing${C_RESET} ${C_DIM}(%s)${C_RESET}\n" \
            "$C_BAD" "config" "${CONFIG_FILE/#$HOME/~}"
        bad=$((bad+1))
    fi

    # 6. log + last run
    if [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
        local total_runs clean_runs kill_runs
        total_runs=$(awk 'END {print NR}' "$LOG_FILE")
        clean_runs=$(grep -c "Clean run" "$LOG_FILE" 2>/dev/null || true)
        kill_runs=$(grep -c "=== Reaped" "$LOG_FILE" 2>/dev/null || true)
        [ -z "$clean_runs" ] && clean_runs=0
        [ -z "$kill_runs" ] && kill_runs=0
        printf "  %s  %-16s ${C_DIM}%d entries · %d clean · %d with kills${C_RESET}\n" \
            "$C_OK" "log" "$total_runs" "$clean_runs" "$kill_runs"

        # Time since last entry.
        local last_line last_ts
        last_line=$(tail -n 1 "$LOG_FILE")
        last_ts=$(printf '%s' "$last_line" | sed -n 's/^\[\([^]]*\)\].*/\1/p')
        if [ -n "$last_ts" ]; then
            local last_epoch now_epoch delta human mark
            last_epoch=$(date -j -f '%Y-%m-%d %H:%M:%S' "$last_ts" +%s 2>/dev/null || echo 0)
            now_epoch=$(date +%s)
            delta=$((now_epoch - last_epoch))
            if   [ "$delta" -lt 0 ];     then human="clock skew"; mark="$C_WRN"; warn=$((warn+1))
            elif [ "$delta" -lt 60 ];    then human="${delta}s ago"; mark="$C_OK"
            elif [ "$delta" -lt 3600 ];  then human="$((delta/60))m ago"; mark="$C_OK"
            elif [ "$delta" -lt 86400 ]; then human="$((delta/3600))h ago"; mark="$C_OK"
            else                              human="$((delta/86400))d ago"; mark="$C_WRN"; warn=$((warn+1))
            fi
            # Warn if it's been much longer than the scheduled interval.
            if [ "$delta" -gt 3900 ] && [ "$mark" = "$C_OK" ]; then
                mark="$C_WRN"; warn=$((warn+1))
            fi
            printf "  %s  %-16s ${C_DIM}%s (%s)${C_RESET}\n" \
                "$mark" "last run" "$human" "$last_ts"
        fi
    else
        printf "  %s  %-16s ${C_YELLOW}no runs yet${C_RESET}\n" "$C_WRN" "log"
        warn=$((warn+1))
    fi

    echo ""
    if [ "$bad" -gt 0 ]; then
        echo "${C_RED}${bad} issue(s) need fixing.${C_RESET} Re-run ${C_BOLD}reap install${C_RESET} to repair the scheduler/app bundle."
        exit 1
    elif [ "$warn" -gt 0 ]; then
        echo "${C_YELLOW}healthy with ${warn} warning(s).${C_RESET}"
    else
        echo "${C_GREEN}all systems green.${C_RESET}"
    fi
}

cmd_logs() {
    if [ ! -f "$LOG_FILE" ]; then
        echo "no log yet. Run 'reap run' or wait for the scheduled sweep"
        return
    fi
    case "${1:-}" in
        -f|--follow) tail -f "$LOG_FILE" ;;
        *) tail -n 40 "$LOG_FILE" ;;
    esac
}

cmd_stats() {
    if [ ! -f "$LOG_FILE" ] || [ ! -s "$LOG_FILE" ]; then
        echo "no history yet. Run reap a few times first."
        return
    fi

    # Cross-platform date arithmetic: BSD date first (macOS), GNU date fallback.
    local week_ago month_ago
    if date -v-7d +%Y-%m-%d >/dev/null 2>&1; then
        week_ago=$(date -v-7d +%Y-%m-%d)
        month_ago=$(date -v-30d +%Y-%m-%d)
    else
        week_ago=$(date -d '-7 days' +%Y-%m-%d 2>/dev/null)
        month_ago=$(date -d '-30 days' +%Y-%m-%d 2>/dev/null)
    fi

    echo "${C_BOLD}reap stats${C_RESET}"
    echo ""

    # Totals + run counts in one awk pass.
    awk -v week="$week_ago" -v month="$month_ago" \
        -v c_bold="$C_BOLD" -v c_dim="$C_DIM" -v c_reset="$C_RESET" '
        /(Killed|Terminated) [0-9]+ \(/ {
            date = substr($0, 2, 10)
            match($0, /(Killed|Terminated) [0-9]+/)
            token = substr($0, RSTART, RLENGTH)
            sub(/^[^ ]+ /, "", token)
            n = token + 0
            tot += n
            if (date >= week)  wk += n
            if (date >= month) mo += n
            kill_runs++
        }
        /Clean run/ { clean_runs++ }
        END {
            total_runs = clean_runs + kill_runs
            printf "%sreaped:%s %s%d%s total  %s%d%s this week  %s%d%s this month\n",
                c_bold, c_reset,
                c_bold, tot+0, c_reset,
                c_bold, wk+0, c_reset,
                c_bold, mo+0, c_reset
            printf "%sruns:%s   %s%d%s total  %s%d%s clean  %s%d%s with kills\n",
                c_bold, c_reset,
                c_bold, total_runs, c_reset,
                c_bold, clean_runs+0, c_reset,
                c_bold, kill_runs+0, c_reset
        }
    ' "$LOG_FILE"

    if [ -s "$WORKTREE_HISTORY_FILE" ]; then
        awk -F '\t' -v week="$week_ago" -v month="$month_ago" \
            -v c_bold="$C_BOLD" -v c_reset="$C_RESET" '
            { tot += $2; n++; if ($1 >= week) wk += $2; if ($1 >= month) mo += $2 }
            END {
                printf "%sdisk:%s   %s%.1f GB%s total  %s%.1f GB%s this week  %s%.1f GB%s this month  (%d worktree cleanups)\n",
                    c_bold, c_reset, c_bold, tot/1048576, c_reset, c_bold, wk/1048576, c_reset,
                    c_bold, mo/1048576, c_reset, n
            }
        ' "$WORKTREE_HISTORY_FILE"
    fi

    # Top 5 most-reaped patterns, sorted by kill count.
    local top
    top=$(awk '
        /(Killed|Terminated) [0-9]+ \(/ {
            match($0, /(Killed|Terminated) [0-9]+/)
            token = substr($0, RSTART, RLENGTH)
            sub(/^[^ ]+ /, "", token)
            n = token + 0
            if (match($0, /: [^)]+\)\. PIDs:/)) {
                pat = substr($0, RSTART + 2, RLENGTH - 10)
                counts[pat] += n
            }
        }
        END {
            for (p in counts) print counts[p]"\t"p
        }
    ' "$LOG_FILE" | sort -rn | head -5)

    if [ -n "$top" ]; then
        echo ""
        echo "${C_BOLD}top targets${C_RESET}"
        printf '%s\n' "$top" | while IFS=$'\t' read -r count pattern; do
            printf "  ${C_BOLD}%-5d${C_RESET}  ${C_DIM}%s${C_RESET}\n" "$count" "$pattern"
        done
    fi

    # Busiest day in the log.
    local busiest
    busiest=$(awk '
        /(Killed|Terminated) [0-9]+ \(/ {
            date = substr($0, 2, 10)
            match($0, /(Killed|Terminated) [0-9]+/)
            token = substr($0, RSTART, RLENGTH)
            sub(/^[^ ]+ /, "", token)
            n = token + 0
            per_day[date] += n
        }
        END {
            for (d in per_day) print per_day[d]"\t"d
        }
    ' "$LOG_FILE" | sort -rn | head -1)

    if [ -n "$busiest" ]; then
        echo ""
        local bc bd
        bc=$(echo "$busiest" | cut -f1)
        bd=$(echo "$busiest" | cut -f2)
        echo "${C_DIM}busiest day: ${bd} (${bc} zombies reaped)${C_RESET}"
    fi
}

cmd_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        err "config not found at $CONFIG_FILE"
        err "run 'reap install' first"
        exit 1
    fi
    "${EDITOR:-vi}" "$CONFIG_FILE"
}

# Find a bundled script (install.sh / uninstall.sh) without curling.
# Search order:
#   1. Next to reap itself                (git clone layout).
#   2. $here/../share/agent-reaper/       (Homebrew pkgshare layout).
# Prints the resolved path on stdout if found, returns non-zero otherwise.
find_bundled_script() {
    local name="$1" here candidate
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    for candidate in "$here/$name" "$here/../share/agent-reaper/$name"; do
        if [ -f "$candidate" ]; then
            # Normalize so "$here/../share/..." becomes an absolute path.
            ( cd "$(dirname "$candidate")" && printf '%s/%s\n' "$(pwd)" "$name" )
            return 0
        fi
    done
    return 1
}

cmd_install() {
    require_nonroot
    local installer
    if installer="$(find_bundled_script install.sh)"; then
        exec bash "$installer" "$@"
    fi
    exec bash -c "curl -fsSL https://raw.githubusercontent.com/tiagonrodrigues/agent-reaper/main/install.sh | bash"
}

cmd_uninstall() {
    require_nonroot
    local uninstaller
    if uninstaller="$(find_bundled_script uninstall.sh)"; then
        exec bash "$uninstaller" "$@"
    fi
    local arg="${1:-}"
    exec bash -c "curl -fsSL https://raw.githubusercontent.com/tiagonrodrigues/agent-reaper/main/uninstall.sh | bash -s -- $arg"
}

show_help() {
    cat <<EOF
${C_BOLD}reap${C_RESET} ${C_DIM}v${REAP_VERSION}${C_RESET}: kill zombie processes left by AI-agent wrappers

${C_BOLD}USAGE${C_RESET}
  reap                    Show status and recent activity
  reap preview            Dry-run: show what would be killed
  reap top                Candidates sorted by memory (nothing killed)
  reap run                Kill zombies now
  reap disk [run]         Idle agent worktrees: preview, or move deps to the Trash now
  reap doctor             Full health check (scheduler, app bundle, config, log)
  reap stats              Historical totals (this week, month, top targets)
  reap logs [-f]          Tail the log (-f to follow)
  reap config             Open config in \$EDITOR
  reap install            (Re)install the LaunchAgent
  reap uninstall [--purge]

${C_BOLD}OPTIONS${C_RESET}
  --version               Print version
  --help                  Show this help

${C_BOLD}FILES${C_RESET}
  ${C_DIM}$CONFIG_FILE${C_RESET}
  ${C_DIM}$LOG_FILE${C_RESET}

${C_BOLD}MORE${C_RESET}
  https://github.com/tiagonrodrigues/agent-reaper
EOF
}

# =============================================================================
# DISPATCH
# =============================================================================
main() {
    case "${1:-status}" in
        run)                 shift; cmd_run "$@" ;;
        preview|dry-run)     shift; cmd_preview "$@" ;;
        top)                 shift; cmd_top "$@" ;;
        disk|worktrees)      shift; cmd_disk "$@" ;;
        doctor|check)        shift; cmd_doctor "$@" ;;
        logs|log)            shift; cmd_logs "$@" ;;
        stats|history)       shift; cmd_stats "$@" ;;
        config|edit)         shift; cmd_config "$@" ;;
        status)              shift; cmd_status "$@" ;;
        install)             shift; cmd_install "$@" ;;
        uninstall|remove)    shift; cmd_uninstall "$@" ;;
        --version|version)   echo "reap v$REAP_VERSION" ;;
        --help|help|-h)      show_help ;;
        *)
            err "unknown command: $1"
            echo ""
            show_help
            exit 2
            ;;
    esac
}

if [ "${REAP_TEST_MODE:-0}" != "1" ]; then
    main "$@"
fi
