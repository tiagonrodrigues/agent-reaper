#!/bin/bash
# reap: kill zombie processes left behind by AI-agent wrappers.
# https://github.com/tiagonrodrigues/agent-reaper
#
# Usage:
#   reap                    Show status (last run, schedule, recent kills)
#   reap preview            Dry-run: show what would be killed, kill nothing
#   reap run                Kill zombies now
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
readonly REAP_VERSION="0.5.0"
readonly REAP_LABEL="co.tiagor.agent-reaper"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agent-reaper"
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/share}/agent-reaper"
readonly CONFIG_DIR LOG_DIR
readonly CONFIG_FILE="$CONFIG_DIR/config.sh"
readonly LOG_FILE="$LOG_DIR/reap.log"

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

# Is this PID's command matching any blocklist entry?
is_blocked() {
    local pid="$1"
    local cmd
    cmd=$(ps -p "$pid" -o command= 2>/dev/null || echo "")
    [ -z "$cmd" ] && return 0  # Gone, don't touch
    local block
    for block in "${BLOCKLIST[@]}"; do
        case "$cmd" in
            *"$block"*) return 0 ;;
        esac
    done
    return 1
}

# Filter a list of PIDs: drop self, parent-of-self, blocked, non-existent.
sanitize_pids() {
    local input="$*"
    local pid
    local keep=()
    for pid in $input; do
        [ "$pid" = "$$" ] && continue
        [ "$pid" = "$PPID" ] && continue
        if is_blocked "$pid"; then
            continue
        fi
        keep+=("$pid")
    done
    echo "${keep[*]:-}"
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
        # MCP servers spawned by AI IDEs. They're almost always children of
        # the IDE, so they become orphans the moment the IDE dies.
        "node.*mcp-server-"
        "node.*@modelcontextprotocol/server-"
    )
    OLD_PROCESS=(
        "ms-playwright/chromium"
        "puppeteer.*chromium"
        "chrome-headless-shell"
    )
    OLD_THRESHOLD_HOURS=2

    # HEAVY_MEMORY: opt-in tier that kills processes whose RSS exceeds
    # HEAVY_MEMORY_MB, regardless of PPID. Empty by default; users must
    # opt in explicitly. All other safety (blocklist, UID scope, max-kill
    # cap, pattern sanity) still applies.
    HEAVY_MEMORY=()
    HEAVY_MEMORY_MB=2000

    VERBOSE=0

    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    fi
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
    esac

    local pids
    pids=$(sanitize_pids "$pids_raw")
    [ -z "$pids" ] && return

    local count
    count=$(echo "$pids" | wc -w | tr -d ' ')
    if [ "$count" -gt "$MAX_KILLS_PER_RULE" ]; then
        warn "rule '$pattern' ($mode) matched $count processes (>$MAX_KILLS_PER_RULE cap)"
        warn "aborting this rule. Review manually, something looks off"
        log "ABORTED rule '$pattern' ($mode): $count matches exceeds cap"
        return
    fi

    local label
    case "$mode" in
        always) label="always" ;;
        orphan) label="orphan (PPID=1)" ;;
        stale)  label="stale (>${thresh}h)" ;;
        heavy)  label="heavy (>${thresh}MB RSS)" ;;
    esac

    if [ "$DRY_RUN" = "1" ]; then
        echo ""
        echo "${C_YELLOW}would kill${C_RESET} ${C_BOLD}$count${C_RESET} process(es), ${C_DIM}$label: $pattern${C_RESET}"
        local pid
        for pid in $pids; do format_pid_row "$pid"; done
        DRY_TOTAL=$((DRY_TOTAL + count))
    else
        # shellcheck disable=SC2086
        kill -9 $pids 2>/dev/null || true
        log "Killed $count ($label: $pattern). PIDs: $pids"
        if [ "$VERBOSE" = "1" ]; then
            echo "${C_RED}killed${C_RESET} $count, ${C_DIM}$label: $pattern${C_RESET}"
        fi
        KILL_TOTAL=$((KILL_TOTAL + count))
    fi
}

process_all_rules() {
    local p
    for p in ${ALWAYS_KILL[@]+"${ALWAYS_KILL[@]}"};   do process_rule always "$p"; done
    for p in ${ORPHAN_ONLY[@]+"${ORPHAN_ONLY[@]}"};   do process_rule orphan "$p"; done
    for p in ${OLD_PROCESS[@]+"${OLD_PROCESS[@]}"};   do process_rule stale  "$p" "$OLD_THRESHOLD_HOURS"; done
    for p in ${HEAVY_MEMORY[@]+"${HEAVY_MEMORY[@]}"}; do process_rule heavy  "$p" "$HEAVY_MEMORY_MB"; done
}

# =============================================================================
# SUBCOMMANDS
# =============================================================================

cmd_run() {
    require_nonroot
    load_config
    DRY_RUN=0
    KILL_TOTAL=0
    process_all_rules

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

    echo "${C_BLUE}${C_BOLD}reap preview${C_RESET} ${C_DIM}(dry-run, nothing will be killed)${C_RESET}"
    process_all_rules

    echo ""
    if [ "$DRY_TOTAL" -eq 0 ]; then
        echo "${C_GREEN}clean${C_RESET}, no zombies detected"
    else
        echo "${C_BOLD}would reap $DRY_TOTAL process(es)${C_RESET}  ${C_DIM}(run 'reap run' to do it)${C_RESET}"
    fi
}

cmd_status() {
    load_config

    echo "${C_BOLD}reap${C_RESET} ${C_DIM}v${REAP_VERSION}${C_RESET}"
    echo ""

    if launchctl list 2>/dev/null | grep -q "$REAP_LABEL"; then
        echo "${C_GREEN}●${C_RESET} scheduled    every 30 minutes via launchd"
    else
        echo "${C_YELLOW}○${C_RESET} not scheduled. Run '${C_BOLD}reap install${C_RESET}'"
    fi

    local a="${#ALWAYS_KILL[@]}" o="${#ORPHAN_ONLY[@]}" s="${#OLD_PROCESS[@]}" h="${#HEAVY_MEMORY[@]}"
    echo "${C_DIM}  config: $a always · $o orphan · $s stale (>${OLD_THRESHOLD_HOURS}h) · $h heavy (>${HEAVY_MEMORY_MB}MB)${C_RESET}"

    if [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
        echo ""
        echo "${C_BOLD}recent activity${C_RESET}"
        tail -n 5 "$LOG_FILE" | while IFS= read -r line; do
            echo "  ${C_DIM}$line${C_RESET}"
        done
    fi

    echo ""
    echo "${C_DIM}commands: reap preview · reap top · reap run · reap doctor · reap stats · reap logs · reap config${C_RESET}"
}

# cmd_top — list processes that match *any* configured rule, sorted by
# resident memory. No kills. Great for "what's about to get reaped?" and
# for demoing the HEAVY_MEMORY tier ("look at that 5GB zombie").
cmd_top() {
    require_nonroot
    load_config

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
            always) pids_raw=$(match_always "$pattern");          tier="always" ;;
            orphan) pids_raw=$(match_orphan "$pattern");          tier="orphan" ;;
            stale)  pids_raw=$(match_stale  "$pattern" "$thresh"); tier="stale(>${thresh}h)" ;;
            heavy)  pids_raw=$(match_heavy  "$pattern" "$thresh"); tier="heavy(>${thresh}MB)" ;;
        esac
        pids=$(sanitize_pids "$pids_raw")
        for pid in $pids; do
            rows="${rows}${pid}"$'\t'"${tier}"$'\t'"${pattern}"$'\n'
        done
    }

    for pattern in ${ALWAYS_KILL[@]+"${ALWAYS_KILL[@]}"};   do add_rows always "$pattern"; done
    for pattern in ${ORPHAN_ONLY[@]+"${ORPHAN_ONLY[@]}"};   do add_rows orphan "$pattern"; done
    for pattern in ${OLD_PROCESS[@]+"${OLD_PROCESS[@]}"};   do add_rows stale  "$pattern" "$OLD_THRESHOLD_HOURS"; done
    for pattern in ${HEAVY_MEMORY[@]+"${HEAVY_MEMORY[@]}"}; do add_rows heavy  "$pattern" "$HEAVY_MEMORY_MB"; done

    if [ -z "$rows" ]; then
        echo "${C_GREEN}clean${C_RESET}, no processes match current rules"
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
        local a=${#ALWAYS_KILL[@]} o=${#ORPHAN_ONLY[@]} s=${#OLD_PROCESS[@]} h=${#HEAVY_MEMORY[@]}
        printf "  %s  %-16s ${C_DIM}%d always · %d orphan · %d stale · %d heavy${C_RESET}\n" \
            "$C_OK" "config" "$a" "$o" "$s" "$h"
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
        /Killed [0-9]+ \(/ {
            date = substr($0, 2, 10)
            match($0, /Killed [0-9]+/)
            n = substr($0, RSTART + 7, RLENGTH - 7) + 0
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

    # Top 5 most-reaped patterns, sorted by kill count.
    local top
    top=$(awk '
        /Killed [0-9]+ \(/ {
            match($0, /Killed [0-9]+/)
            n = substr($0, RSTART + 7, RLENGTH - 7) + 0
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
        /Killed [0-9]+ \(/ {
            date = substr($0, 2, 10)
            match($0, /Killed [0-9]+/)
            n = substr($0, RSTART + 7, RLENGTH - 7) + 0
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

main "$@"
