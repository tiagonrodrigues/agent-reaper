#!/bin/bash
# agent-reaper installer
# https://github.com/tiagonrodrigues/agent-reaper
#
# Installs the reaper script to ~/.local/bin and schedules it via launchd.
# Safe to re-run — it replaces existing installation.

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/tiagonrodrigues/agent-reaper/main"
LABEL="co.tiagor.agent-reaper"
BIN_DIR="$HOME/.local/bin"
SCRIPT_PATH="$BIN_DIR/agent-reaper.sh"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agent-reaper"
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/share}/agent-reaper"

# --- Platform guard ---------------------------------------------------------
if [ "$(uname)" != "Darwin" ]; then
    echo "❌ agent-reaper is macOS-only (uses launchd)." >&2
    exit 1
fi

echo "🪦 Installing agent-reaper..."

# --- Fetch or copy files ----------------------------------------------------
mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$LOG_DIR" "$(dirname "$PLIST_PATH")"

if [ -f "$(dirname "$0")/kill-zombies.sh" ]; then
    # Local install (cloned repo)
    cp "$(dirname "$0")/kill-zombies.sh" "$SCRIPT_PATH"
    PLIST_TEMPLATE="$(dirname "$0")/com.example.agent-reaper.plist"
    CONFIG_TEMPLATE="$(dirname "$0")/config.example.sh"
else
    # Remote install (curl | bash)
    curl -fsSL "$REPO_RAW/kill-zombies.sh" -o "$SCRIPT_PATH"
    PLIST_TEMPLATE=$(mktemp)
    CONFIG_TEMPLATE=$(mktemp)
    curl -fsSL "$REPO_RAW/com.example.agent-reaper.plist" -o "$PLIST_TEMPLATE"
    curl -fsSL "$REPO_RAW/config.example.sh" -o "$CONFIG_TEMPLATE"
fi

chmod +x "$SCRIPT_PATH"
echo "  ✓ Script installed to $SCRIPT_PATH"

# --- Render plist from template --------------------------------------------
sed \
    -e "s|{{LABEL}}|$LABEL|g" \
    -e "s|{{SCRIPT_PATH}}|$SCRIPT_PATH|g" \
    -e "s|{{LOG_DIR}}|$LOG_DIR|g" \
    "$PLIST_TEMPLATE" > "$PLIST_PATH"
echo "  ✓ LaunchAgent written to $PLIST_PATH"

# --- Seed config if missing -------------------------------------------------
if [ ! -f "$CONFIG_DIR/config.sh" ]; then
    cp "$CONFIG_TEMPLATE" "$CONFIG_DIR/config.sh"
    echo "  ✓ Config seeded at $CONFIG_DIR/config.sh"
else
    echo "  • Config already exists at $CONFIG_DIR/config.sh (left untouched)"
fi

# --- Load LaunchAgent -------------------------------------------------------
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"
echo "  ✓ LaunchAgent loaded"

# --- Sanity check -----------------------------------------------------------
if launchctl list | grep -q "$LABEL"; then
    echo ""
    echo "💀 agent-reaper is live. First run happens now, then every 30 minutes."
    echo ""
    echo "   Customize   →  $CONFIG_DIR/config.sh"
    echo "   Logs        →  $LOG_DIR/reap.log"
    echo "   Run now     →  $SCRIPT_PATH"
    echo "   Uninstall   →  curl -fsSL $REPO_RAW/uninstall.sh | bash"
else
    echo "⚠️  Install completed but LaunchAgent not showing in launchctl list." >&2
    exit 1
fi
