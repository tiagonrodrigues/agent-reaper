#!/bin/bash
# agent-reaper configuration
# Copy to ~/.config/agent-reaper/config.sh and customize.
#
# Three tiers of aggression. Move patterns between arrays to fit your workflow.
#
# shellcheck disable=SC2034
# (Variables below are sourced by reap, not used standalone in this file.)

# =============================================================================
# ALWAYS_KILL: patterns killed unconditionally on every run.
#
# Use this for tools you NEVER use but that keep spawning (e.g. transitive
# dependencies, background update daemons you don't want).
#
# Example: I don't use opencode, but something keeps launching it. Nuke always.
# =============================================================================
ALWAYS_KILL=(
    # "opencode-ai/bin/.opencode"
)

# =============================================================================
# ORPHAN_ONLY: patterns killed only if their parent process died (PPID=1).
#
# This is the SAFE default for AI-agent CLIs. Active sessions always have
# their wrapper (T3 Code, terminal emulator, etc.) as parent. Only sessions
# whose wrapper already closed become orphans. Those are the zombies.
# =============================================================================
ORPHAN_ONLY=(
    "claude --output-format stream-json"            # Claude Code CLI
    "cursor-agent.*stream"                          # Cursor Agent
    "codex.*--output-format"                        # OpenAI Codex CLI
    "aider.*--stream"                               # Aider
    # MCP servers. They're almost always children of an AI IDE, so they
    # become orphans the moment the IDE dies.
    "node.*mcp-server-"                             # third-party MCP servers
    "node.*@modelcontextprotocol/server-"           # official MCP servers
    # "gemini --stream"                             # add your own
)

# =============================================================================
# OLD_PROCESS: patterns killed only if older than OLD_THRESHOLD_HOURS.
#
# For tools that should be short-lived but sometimes hang. Playwright's
# headless browsers are notorious: they leak when tests crash mid-run.
# =============================================================================
OLD_PROCESS=(
    "ms-playwright/chromium"
    "puppeteer.*chromium"
    "chrome-headless-shell"                         # Playwright/Puppeteer
    # "selenium.*chromedriver"
)
OLD_THRESHOLD_HOURS=2

# =============================================================================
# Other options
# =============================================================================
VERBOSE=0   # 1 = also print to stderr (useful when debugging)
