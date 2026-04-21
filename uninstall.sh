#!/bin/bash
# agent-reaper uninstaller
# https://github.com/tiagonrodrigues/agent-reaper
#
# Removes the LaunchAgent and `reap` CLI. Preserves config and logs by default.
# Pass --purge to also remove config and logs.

set -euo pipefail

readonly LABEL="co.tiagor.agent-reaper"
readonly BIN_PATH="$HOME/.local/bin/reap"
readonly LEGACY_SCRIPT="$HOME/.local/bin/agent-reaper.sh"
readonly PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
readonly CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agent-reaper"
readonly LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/share}/agent-reaper"

echo "🪦 Uninstalling agent-reaper..."

# Unload & remove the LaunchAgent
if [ -f "$PLIST_PATH" ]; then
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    rm -f "$PLIST_PATH"
    echo "  ✓ LaunchAgent removed"
fi

# Remove reap CLI (and legacy script if present)
for path in "$BIN_PATH" "$LEGACY_SCRIPT"; do
    if [ -f "$path" ]; then
        rm -f "$path"
        echo "  ✓ Removed $path"
    fi
done

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
