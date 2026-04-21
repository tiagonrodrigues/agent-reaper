#!/bin/bash
# agent-reaper installer
# https://github.com/tiagonrodrigues/agent-reaper
#
# Sets up the Agent Reaper.app bundle at ~/Applications, writes the
# LaunchAgent, and seeds the config. Works in three modes:
#
#   1. Local clone:   `./install.sh` from a cloned repo.
#   2. Remote curl:   `curl ... | bash` (self-fetches templates).
#   3. Homebrew:      `reap install` with reap already on PATH
#                     (uses templates from brew's share dir).
#
# Safe to re-run. Idempotent. Migrates older layouts automatically.

set -euo pipefail

readonly REPO_RAW="https://raw.githubusercontent.com/tiagonrodrigues/agent-reaper/main"
readonly VERSION="0.4.1"
readonly LABEL="co.tiagor.agent-reaper"

readonly LOCAL_BIN_DIR="$HOME/.local/bin"
readonly LOCAL_BIN_PATH="$LOCAL_BIN_DIR/reap"
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
mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$(dirname "$PLIST_PATH")"
mkdir -p "$APP_MACOS_DIR" "$APP_RESOURCES_DIR"

# --- Decide installation mode ----------------------------------------------
# MODE=local    → we're inside a clone; install reap CLI to ~/.local/bin.
# MODE=provided → reap is already on PATH (e.g. Homebrew); use it in place.
# MODE=remote   → curl | bash; fetch everything into /tmp.
HERE="$(cd "$(dirname "$0")" && pwd)"
CLEANUP_TEMPLATES=0

if [ -f "$HERE/reap.sh" ] && [ -f "$HERE/templates/launchd.plist" ]; then
    MODE="local"
    REAP_SRC="$HERE/reap.sh"
    TEMPLATE_DIR="$HERE/templates"
elif [ -f "$HERE/templates/launchd.plist" ] && command -v reap >/dev/null 2>&1; then
    MODE="provided"
    REAP_SRC=""                        # not needed; reap is already installed
    TEMPLATE_DIR="$HERE/templates"
else
    MODE="remote"
    REAP_SRC=$(mktemp)
    TEMPLATE_DIR=$(mktemp -d)
    mkdir -p "$TEMPLATE_DIR/app-bundle"
    curl -fsSL "$REPO_RAW/reap.sh"                                 -o "$REAP_SRC"
    curl -fsSL "$REPO_RAW/templates/launchd.plist"                 -o "$TEMPLATE_DIR/launchd.plist"
    curl -fsSL "$REPO_RAW/templates/config.example.sh"             -o "$TEMPLATE_DIR/config.example.sh"
    curl -fsSL "$REPO_RAW/templates/app-bundle/Info.plist.template" -o "$TEMPLATE_DIR/app-bundle/Info.plist.template"
    curl -fsSL "$REPO_RAW/templates/app-bundle/AgentReaper.sh"     -o "$TEMPLATE_DIR/app-bundle/AgentReaper.sh"
    CLEANUP_TEMPLATES=1
fi

readonly PLIST_TEMPLATE="$TEMPLATE_DIR/launchd.plist"
readonly CONFIG_TEMPLATE="$TEMPLATE_DIR/config.example.sh"
readonly APP_INFO_TEMPLATE="$TEMPLATE_DIR/app-bundle/Info.plist.template"
readonly APP_EXEC_TEMPLATE="$TEMPLATE_DIR/app-bundle/AgentReaper.sh"

# --- Install (or locate) the reap CLI --------------------------------------
case "$MODE" in
    local|remote)
        mkdir -p "$LOCAL_BIN_DIR"
        cp "$REAP_SRC" "$LOCAL_BIN_PATH"
        chmod +x "$LOCAL_BIN_PATH"
        REAP_PATH="$LOCAL_BIN_PATH"
        echo "  reap CLI installed to $REAP_PATH"
        ;;
    provided)
        REAP_PATH="$(command -v reap)"
        echo "  reap CLI already on PATH at $REAP_PATH (leaving in place)"
        ;;
esac

# --- Build the .app bundle --------------------------------------------------
# Gives macOS a proper name and identity for Login Items, Activity Monitor,
# and the background-item security pane. Without this the LaunchAgent would
# show up as "bash" under "Item from unidentified developer".

# 1. Inner executable. Renders from template with REAP_PATH substituted so
#    the .app launches the correct reap binary (brew, ~/.local/bin, etc.).
sed "s|{{REAP_PATH}}|$REAP_PATH|g" "$APP_EXEC_TEMPLATE" > "$APP_EXEC_PATH"
chmod +x "$APP_EXEC_PATH"

# 2. Info.plist with version substitution.
sed "s|{{VERSION}}|$VERSION|g" "$APP_INFO_TEMPLATE" > "$APP_INFO_PLIST"

# 3. Ad-hoc code signature. This is what makes macOS stop calling it
#    "unidentified developer" in Login Items. Not notarized (that would
#    require an Apple Developer account), but ad-hoc is enough for local
#    use and gives the bundle a real identity.
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
    rm -rf "$REAP_SRC" "$TEMPLATE_DIR"
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
    if [ "$MODE" != "provided" ]; then
        case ":$PATH:" in
            *":$LOCAL_BIN_DIR:"*) ;;
            *) echo "  note: $LOCAL_BIN_DIR is not on your \$PATH. Add it to use 'reap' directly." ;;
        esac
    fi
    echo "  try it:  reap           (status)"
    echo "           reap preview   (dry-run)"
    echo "           reap logs      (recent activity)"
else
    echo "Install finished but LaunchAgent isn't showing in launchctl list." >&2
    exit 1
fi
