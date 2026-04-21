#!/bin/bash
# agent-reaper installer
# https://github.com/tiagonrodrigues/agent-reaper
#
# Installs the `reap` CLI, packages it as "Agent Reaper.app" so macOS
# identifies it properly (Login Items, Activity Monitor, etc.), and
# schedules it every 30 minutes via launchd.
#
# Safe to re-run. Idempotent. Migrates older layouts automatically.

set -euo pipefail

readonly REPO_RAW="https://raw.githubusercontent.com/tiagonrodrigues/agent-reaper/main"
readonly VERSION="0.3.0"
readonly LABEL="co.tiagor.agent-reaper"

readonly BIN_DIR="$HOME/.local/bin"
readonly BIN_PATH="$BIN_DIR/reap"
readonly PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
readonly CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agent-reaper"
readonly LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/share}/agent-reaper"

readonly APP_DIR="$HOME/Applications/Agent Reaper.app"
readonly APP_MACOS_DIR="$APP_DIR/Contents/MacOS"
readonly APP_RESOURCES_DIR="$APP_DIR/Contents/Resources"
readonly APP_INFO_PLIST="$APP_DIR/Contents/Info.plist"
readonly APP_EXEC_PATH="$APP_MACOS_DIR/AgentReaper"

# --- Platform guard ---------------------------------------------------------
if [ "$(uname)" != "Darwin" ]; then
    echo "agent-reaper is macOS-only (uses launchd)." >&2
    exit 1
fi

if [ "$(id -u)" = "0" ]; then
    echo "don't run the installer as root." >&2
    exit 1
fi

echo "Installing agent-reaper v$VERSION..."

# --- Migrate from pre-0.2 installs -----------------------------------------
if [ -f "$HOME/.local/bin/agent-reaper.sh" ]; then
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    rm -f "$HOME/.local/bin/agent-reaper.sh"
    echo "  Migrated from pre-0.2 layout (removed agent-reaper.sh)"
fi
if [ -f "$HOME/.local/share/kill-zombies.log" ]; then
    mv "$HOME/.local/share/kill-zombies.log" "$LOG_DIR/reap.log" 2>/dev/null || true
fi

# --- Directories ------------------------------------------------------------
mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$LOG_DIR" "$(dirname "$PLIST_PATH")"
mkdir -p "$APP_MACOS_DIR" "$APP_RESOURCES_DIR"

# --- Locate source files (local clone or remote) ---------------------------
HERE="$(cd "$(dirname "$0")" && pwd)"
CLEANUP_TEMPLATES=0

if [ -f "$HERE/reap.sh" ] && [ -f "$HERE/templates/launchd.plist" ]; then
    # Local install (cloned repo)
    REAP_SRC="$HERE/reap.sh"
    PLIST_TEMPLATE="$HERE/templates/launchd.plist"
    CONFIG_TEMPLATE="$HERE/templates/config.example.sh"
    APP_INFO_TEMPLATE="$HERE/templates/app-bundle/Info.plist.template"
    APP_EXEC_TEMPLATE="$HERE/templates/app-bundle/AgentReaper.sh"
else
    # Remote install (curl | bash)
    REAP_SRC=$(mktemp)
    PLIST_TEMPLATE=$(mktemp)
    CONFIG_TEMPLATE=$(mktemp)
    APP_INFO_TEMPLATE=$(mktemp)
    APP_EXEC_TEMPLATE=$(mktemp)
    curl -fsSL "$REPO_RAW/reap.sh"                              -o "$REAP_SRC"
    curl -fsSL "$REPO_RAW/templates/launchd.plist"              -o "$PLIST_TEMPLATE"
    curl -fsSL "$REPO_RAW/templates/config.example.sh"          -o "$CONFIG_TEMPLATE"
    curl -fsSL "$REPO_RAW/templates/app-bundle/Info.plist.template" -o "$APP_INFO_TEMPLATE"
    curl -fsSL "$REPO_RAW/templates/app-bundle/AgentReaper.sh"  -o "$APP_EXEC_TEMPLATE"
    CLEANUP_TEMPLATES=1
fi

# --- Install reap CLI -------------------------------------------------------
cp "$REAP_SRC" "$BIN_PATH"
chmod +x "$BIN_PATH"
echo "  reap CLI installed to $BIN_PATH"

# --- Build the .app bundle --------------------------------------------------
# So macOS shows "Agent Reaper" in Login Items, Activity Monitor, etc.
# instead of "bash" with "unidentified developer" under it.

# 1. Inner executable: a thin launcher that execs `reap run`.
cp "$APP_EXEC_TEMPLATE" "$APP_EXEC_PATH"
chmod +x "$APP_EXEC_PATH"

# 2. Info.plist with version substitution.
sed "s|{{VERSION}}|$VERSION|g" "$APP_INFO_TEMPLATE" > "$APP_INFO_PLIST"

# 3. Ad-hoc code signature. This is what makes macOS stop calling it
#    "unidentified developer" in Login Items. It's not notarized (that would
#    require an Apple Developer account), but ad-hoc is enough for a locally
#    installed tool and for the bundle identity to be recognized.
if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || \
        echo "  (codesign failed; continuing unsigned)" >&2
fi

echo "  Agent Reaper.app built at $APP_DIR"

# --- Render LaunchAgent plist ----------------------------------------------
sed \
    -e "s|{{LABEL}}|$LABEL|g" \
    -e "s|{{APP_EXEC_PATH}}|$APP_EXEC_PATH|g" \
    -e "s|{{LOG_DIR}}|$LOG_DIR|g" \
    "$PLIST_TEMPLATE" > "$PLIST_PATH"
echo "  LaunchAgent written to $PLIST_PATH"

# --- Seed config if missing -------------------------------------------------
if [ ! -f "$CONFIG_DIR/config.sh" ]; then
    cp "$CONFIG_TEMPLATE" "$CONFIG_DIR/config.sh"
    echo "  Config seeded at $CONFIG_DIR/config.sh"
else
    echo "  Config preserved at $CONFIG_DIR/config.sh"
fi

# --- Cleanup ---------------------------------------------------------------
if [ "$CLEANUP_TEMPLATES" = "1" ]; then
    rm -f "$REAP_SRC" "$PLIST_TEMPLATE" "$CONFIG_TEMPLATE" \
          "$APP_INFO_TEMPLATE" "$APP_EXEC_TEMPLATE"
fi

# --- Load LaunchAgent -------------------------------------------------------
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"
echo "  LaunchAgent loaded"

# --- Sanity check -----------------------------------------------------------
if launchctl list | grep -q "$LABEL"; then
    echo ""
    echo "agent-reaper is live. First sweep runs now, next in 30 minutes."
    echo ""
    case ":$PATH:" in
        *":$BIN_DIR:"*) ;;
        *) echo "  note: $BIN_DIR is not on your \$PATH. Add it to use 'reap' directly." ;;
    esac
    echo "  try it:  reap           (status)"
    echo "           reap preview   (dry-run)"
    echo "           reap logs      (recent activity)"
else
    echo "Install finished but LaunchAgent isn't showing in launchctl list." >&2
    exit 1
fi
