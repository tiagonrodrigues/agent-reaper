#!/bin/bash
# agent-reaper — Kills orphaned AI-agent processes that wrappers forgot to clean up.
# https://github.com/tiagonrodrigues/agent-reaper
#
# Safe by design: matches only stale/orphan processes, never active ones.
# Runs via LaunchAgent every 30 minutes. See install.sh.
#
# Customize by editing ~/.config/agent-reaper/config.sh (created by install.sh).

set -u

# --- Resolve config ---------------------------------------------------------
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agent-reaper"
CONFIG_FILE="$CONFIG_DIR/config.sh"
LOG_FILE="${XDG_STATE_HOME:-$HOME/.local/share}/agent-reaper/reap.log"

mkdir -p "$CONFIG_DIR" "$(dirname "$LOG_FILE")"

# Defaults — overridable in config.sh
# ALWAYS_KILL: patterns to kill unconditionally (you don't use these tools)
ALWAYS_KILL=()
# ORPHAN_ONLY: patterns to kill only if PPID=1 (parent died → orphan)
ORPHAN_ONLY=(
    "claude --output-format stream-json"
    "cursor-agent.*stream"
    "codex.*--output-format"
    "aider.*--stream"
)
# OLD_PROCESS: patterns to kill only if older than OLD_THRESHOLD_HOURS
OLD_PROCESS=(
    "ms-playwright/chromium"
    "puppeteer.*chromium"
)
OLD_THRESHOLD_HOURS=2

# Logging
VERBOSE=0

# Load user config if exists
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# --- Helpers ----------------------------------------------------------------
ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG_FILE"; [ "$VERBOSE" = "1" ] && echo "[$(ts)] $*" >&2; }

total_killed=0

# Kill PIDs, log count with reason
reap() {
    local reason="$1"; shift
    local pids="$*"
    [ -z "$pids" ] && return 0
    local n
    n=$(echo "$pids" | wc -w | tr -d ' ')
    # shellcheck disable=SC2086
    kill -9 $pids 2>/dev/null || true
    log "Killed $n process(es) — $reason"
    total_killed=$((total_killed + n))
}

# --- 1. ALWAYS_KILL patterns ------------------------------------------------
for pattern in ${ALWAYS_KILL[@]+"${ALWAYS_KILL[@]}"}; do
    [ -z "$pattern" ] && continue
    pids=$(pgrep -f "$pattern" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
    reap "always-kill: $pattern" "$pids"
done

# --- 2. ORPHAN_ONLY patterns (PPID=1) ---------------------------------------
for pattern in ${ORPHAN_ONLY[@]+"${ORPHAN_ONLY[@]}"}; do
    [ -z "$pattern" ] && continue
    pids=$(ps -eo pid,ppid,command | awk -v pat="$pattern" '$2==1 && $0 ~ pat {print $1}' | tr '\n' ' ' | sed 's/ $//')
    reap "orphan (PPID=1): $pattern" "$pids"
done

# --- 3. OLD_PROCESS patterns (age > threshold) ------------------------------
for pattern in ${OLD_PROCESS[@]+"${OLD_PROCESS[@]}"}; do
    [ -z "$pattern" ] && continue
    pids=$(ps -eo pid,etime,command | awk -v pat="$pattern" -v thresh="$OLD_THRESHOLD_HOURS" '
        $0 ~ pat {
            split($2, t, "-")
            if (length(t) == 2) { days = t[1]; rest = t[2] } else { days = 0; rest = t[1] }
            split(rest, hms, ":")
            if (length(hms) == 3) { h = hms[1] } else { h = 0 }
            if (days >= 1 || h >= thresh) print $1
        }
    ' | tr '\n' ' ' | sed 's/ $//')
    reap "stale (>${OLD_THRESHOLD_HOURS}h): $pattern" "$pids"
done

# --- Wrap up ----------------------------------------------------------------
if [ $total_killed -eq 0 ]; then
    log "Clean run — no zombies found"
else
    log "=== Reaped $total_killed process(es) ==="
fi

# Log rotation: keep last 500 lines
if [ -f "$LOG_FILE" ]; then
    tail -n 500 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
fi

exit 0
