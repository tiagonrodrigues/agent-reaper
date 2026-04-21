#!/bin/bash
# agent-reaper uninstaller
# Removes the LaunchAgent and script. Preserves config and logs by default.
# Pass --purge to also remove config and logs.

set -euo pipefail

LABEL="co.tiagor.agent-reaper"
SCRIPT_PATH="$HOME/.local/bin/agent-reaper.sh"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agent-reaper"
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/share}/agent-reaper"

echo "🪦 Uninstalling agent-reaper..."

# Unload & remove the LaunchAgent
if [ -f "$PLIST_PATH" ]; then
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    rm -f "$PLIST_PATH"
    echo "  ✓ LaunchAgent removed"
fi

# Remove script
if [ -f "$SCRIPT_PATH" ]; then
    rm -f "$SCRIPT_PATH"
    echo "  ✓ Script removed"
fi

# Purge config + logs if requested
if [ "${1:-}" = "--purge" ]; then
    rm -rf "$CONFIG_DIR" "$LOG_DIR"
    echo "  ✓ Config and logs purged"
else
    echo ""
    echo "  • Config preserved at $CONFIG_DIR"
    echo "  • Logs preserved at   $LOG_DIR"
    echo "    (pass --purge to remove these too)"
fi

echo ""
echo "Gone. Your zombies are free to roam again."
