#!/bin/bash
# reap — kill zombie processes left behind by AI-agent wrappers.
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
# Note: `set -e` is intentionally avoided — reap should never crash on a single
# misbehaving pattern; each rule is isolated and errors are logged.

# =============================================================================
# CONSTANTS
# =============================================================================
readonly REAP_VERSION="0.2.0"
readonly REAP_LABEL="co.tiagor.agent-reaper"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agent-reaper"
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/share}/agent-reaper"
readonly CONFIG_DIR LOG_DIR
readonly CONFIG_FILE="$CONFIG_DIR/config.sh"
readonly LOG_FILE="$LOG_DIR/reap.log"

# Safety: max PIDs a single rule may kill in one run. If exceeded, rule is
# aborted and logged — something's probably wrong (user pattern too broad).
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
# HARD SAFETY — applied to every rule
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
    [ -z "$cmd" ] && return 0  # Gone — don't touch
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
    )
    OLD_PROCESS=(
        "ms-playwright/chromium"
        "puppeteer.*chromium"
    )
    OLD_THRESHOLD_HOURS=2
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
    esac

    local pids
    pids=$(sanitize_pids "$pids_raw")
    [ -z "$pids" ] && return

    local count
    count=$(echo "$pids" | wc -w | tr -d ' ')
    if [ "$count" -gt "$MAX_KILLS_PER_RULE" ]; then
        warn "rule '$pattern' ($mode) matched $count processes (>$MAX_KILLS_PER_RULE cap)"
        warn "aborting this rule — review manually, something looks off"
        log "ABORTED rule '$pattern' ($mode): $count matches exceeds cap"
        return
    fi

    local label
    case "$mode" in
        always) label="always" ;;
        orphan) label="orphan (PPID=1)" ;;
        stale)  label="stale (>${thresh}h)" ;;
    esac

    if [ "$DRY_RUN" = "1" ]; then
        echo ""
        echo "${C_YELLOW}would kill${C_RESET} ${C_BOLD}$count${C_RESET} process(es) — ${C_DIM}$label: $pattern${C_RESET}"
        local pid
        for pid in $pids; do format_pid_row "$pid"; done
        DRY_TOTAL=$((DRY_TOTAL + count))
    else
        # shellcheck disable=SC2086
        kill -9 $pids 2>/dev/null || true
        log "Killed $count ($label: $pattern) — PIDs: $pids"
        if [ "$VERBOSE" = "1" ]; then
            echo "${C_RED}killed${C_RESET} $count — ${C_DIM}$label: $pattern${C_RESET}"
        fi
        KILL_TOTAL=$((KILL_TOTAL + count))
    fi
}

process_all_rules() {
    local p
    for p in ${ALWAYS_KILL[@]+"${ALWAYS_KILL[@]}"}; do process_rule always "$p"; done
    for p in ${ORPHAN_ONLY[@]+"${ORPHAN_ONLY[@]}"}; do process_rule orphan "$p"; done
    for p in ${OLD_PROCESS[@]+"${OLD_PROCESS[@]}"}; do process_rule stale  "$p" "$OLD_THRESHOLD_HOURS"; done
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
        log "Clean run — no zombies found"
        [ "$VERBOSE" = "1" ] && echo "${C_GREEN}clean${C_RESET} — no zombies found"
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

    echo "${C_BLUE}${C_BOLD}reap preview${C_RESET} ${C_DIM}(dry-run — nothing will be killed)${C_RESET}"
    process_all_rules

    echo ""
    if [ "$DRY_TOTAL" -eq 0 ]; then
        echo "${C_GREEN}clean${C_RESET} — no zombies detected"
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
        echo "${C_YELLOW}○${C_RESET} not scheduled — run '${C_BOLD}reap install${C_RESET}'"
    fi

    local a="${#ALWAYS_KILL[@]}" o="${#ORPHAN_ONLY[@]}" s="${#OLD_PROCESS[@]}"
    echo "${C_DIM}  config: $a always-kill · $o orphan-only · $s stale (>${OLD_THRESHOLD_HOURS}h)${C_RESET}"

    if [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
        echo ""
        echo "${C_BOLD}recent activity${C_RESET}"
        tail -n 5 "$LOG_FILE" | while IFS= read -r line; do
            echo "  ${C_DIM}$line${C_RESET}"
        done
    fi

    echo ""
    echo "${C_DIM}commands: reap preview · reap run · reap logs · reap config${C_RESET}"
}

cmd_logs() {
    if [ ! -f "$LOG_FILE" ]; then
        echo "no log yet — run 'reap run' or wait for the scheduled sweep"
        return
    fi
    case "${1:-}" in
        -f|--follow) tail -f "$LOG_FILE" ;;
        *) tail -n 40 "$LOG_FILE" ;;
    esac
}

cmd_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        err "config not found at $CONFIG_FILE"
        err "run 'reap install' first"
        exit 1
    fi
    "${EDITOR:-vi}" "$CONFIG_FILE"
}

cmd_install() {
    require_nonroot
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local installer="$here/install.sh"
    if [ ! -f "$installer" ]; then
        exec bash -c "curl -fsSL https://raw.githubusercontent.com/tiagonrodrigues/agent-reaper/main/install.sh | bash"
    fi
    exec bash "$installer" "$@"
}

cmd_uninstall() {
    require_nonroot
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local uninstaller="$here/uninstall.sh"
    if [ ! -f "$uninstaller" ]; then
        local arg="${1:-}"
        exec bash -c "curl -fsSL https://raw.githubusercontent.com/tiagonrodrigues/agent-reaper/main/uninstall.sh | bash -s -- $arg"
    fi
    exec bash "$uninstaller" "$@"
}

show_help() {
    cat <<EOF
${C_BOLD}reap${C_RESET} ${C_DIM}v${REAP_VERSION}${C_RESET} — kill zombie processes left by AI-agent wrappers

${C_BOLD}USAGE${C_RESET}
  reap                    Show status and recent activity
  reap preview            Dry-run: show what would be killed
  reap run                Kill zombies now
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
        logs|log)            shift; cmd_logs "$@" ;;
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
