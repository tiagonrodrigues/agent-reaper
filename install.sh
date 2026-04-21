#!/bin/bash
# agent-reaper installer
# https://github.com/tiagonrodrigues/agent-reaper
#
# Installs the `reap` CLI to ~/.local/bin/reap and schedules it via launchd.
# Safe to re-run — idempotent, migrates pre-0.2 layouts automatically.

set -euo pipefail

readonly REPO_RAW="https://raw.githubusercontent.com/tiagonrodrigues/agent-reaper/main"
readonly LABEL="co.tiagor.agent-reaper"
readonly BIN_DIR="$HOME/.local/bin"
readonly BIN_PATH="$BIN_DIR/reap"
readonly PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
readonly CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agent-reaper"
readonly LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/share}/agent-reaper"

# --- Platform guard ---------------------------------------------------------
if [ "$(uname)" != "Darwin" ]; then
    echo "❌ agent-reaper is macOS-only (uses launchd)." >&2
    exit 1
fi

if [ "$(id -u)" = "0" ]; then
    echo "❌ don't run the installer as root." >&2
    exit 1
fi

echo "🪦 Installing agent-reaper..."

# --- Migrate from pre-0.2 installs -----------------------------------------
if [ -f "$HOME/.local/bin/agent-reaper.sh" ]; then
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    rm -f "$HOME/.local/bin/agent-reaper.sh"
    echo "  ✓ Migrated from pre-0.2 layout (removed agent-reaper.sh)"
fi
# Also clear legacy log filename if present
if [ -f "$HOME/.local/share/kill-zombies.log" ]; then
    mv "$HOME/.local/share/kill-zombies.log" "$LOG_DIR/reap.log" 2>/dev/null || true
fi

# --- Fetch or copy files ----------------------------------------------------
mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$LOG_DIR" "$(dirname "$PLIST_PATH")"

HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$HERE/reap.sh" ]; then
    # Local install (cloned repo)
    cp "$HERE/reap.sh" "$BIN_PATH"
    PLIST_TEMPLATE="$HERE/com.example.agent-reaper.plist"
    CONFIG_TEMPLATE="$HERE/config.example.sh"
    CLEANUP_TEMPLATES=0
else
    # Remote install (curl | bash)
    curl -fsSL "$REPO_RAW/reap.sh" -o "$BIN_PATH"
    PLIST_TEMPLATE=$(mktemp)
    CONFIG_TEMPLATE=$(mktemp)
    curl -fsSL "$REPO_RAW/com.example.agent-reaper.plist" -o "$PLIST_TEMPLATE"
    curl -fsSL "$REPO_RAW/config.example.sh" -o "$CONFIG_TEMPLATE"
    CLEANUP_TEMPLATES=1
fi

chmod +x "$BIN_PATH"
echo "  ✓ reap CLI installed to $BIN_PATH"

# --- Render plist from template --------------------------------------------
# The LaunchAgent invokes: $BIN_PATH run
sed \
    -e "s|{{LABEL}}|$LABEL|g" \
    -e "s|{{BIN_PATH}}|$BIN_PATH|g" \
    -e "s|{{LOG_DIR}}|$LOG_DIR|g" \
    "$PLIST_TEMPLATE" > "$PLIST_PATH"
echo "  ✓ LaunchAgent written to $PLIST_PATH"

# --- Seed config if missing -------------------------------------------------
if [ ! -f "$CONFIG_DIR/config.sh" ]; then
    cp "$CONFIG_TEMPLATE" "$CONFIG_DIR/config.sh"
    echo "  ✓ Config seeded at $CONFIG_DIR/config.sh"
else
    echo "  • Config preserved at $CONFIG_DIR/config.sh"
fi

# Cleanup temp templates if we fetched remotely
if [ "$CLEANUP_TEMPLATES" = "1" ]; then
    rm -f "$PLIST_TEMPLATE" "$CONFIG_TEMPLATE"
fi

# --- Load LaunchAgent -------------------------------------------------------
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"
echo "  ✓ LaunchAgent loaded"

# --- Sanity check -----------------------------------------------------------
if launchctl list | grep -q "$LABEL"; then
    echo ""
    echo "💀 agent-reaper is live. First sweep runs now, next in 30 minutes."
    echo ""
    # Best-effort: warn if ~/.local/bin isn't on PATH
    case ":$PATH:" in
        *":$BIN_DIR:"*) ;;
        *) echo "   ${BIN_DIR} is not on your \$PATH — add it to use 'reap' directly." ;;
    esac
    echo "   try it:   reap           (status)"
    echo "             reap preview   (dry-run)"
    echo "             reap logs      (recent activity)"
else
    echo "⚠️  Install completed but LaunchAgent not showing in launchctl list." >&2
    exit 1
fi
