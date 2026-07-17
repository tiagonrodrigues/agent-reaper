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
    "codex app-server --listen stdio"               # orphaned Codex MCP host
    "bun .*/\\.bun/bin/omp"                        # orphaned Oh My Pi session
    "__omp_worker_"                                # orphaned OMP worker
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
    "agent-browser/bin/agent-browser-"              # idle agent-browser daemon
    "mcp-remote"                                    # detached remote MCP wrapper
    "shadcn mcp"                                    # detached shadcn MCP
    "@modelcontextprotocol/server-"                  # official MCP servers
    "node.*mcp-server-"                             # third-party MCP servers
    "convex.*mcp start"                             # Convex MCP wrapper/server
    "bun .*/\\.bun/bin/omp"                        # detached Oh My Pi session
    "__omp_worker_"                                # detached OMP worker
    # "selenium.*chromedriver"
)
OLD_THRESHOLD_HOURS=2

# =============================================================================
# HEAVY_MEMORY: detached matching processes are considered when RSS exceeds
# HEAVY_MEMORY_MB. Live terminal trees and interactive browsers are always
# protected, even when they exceed this ceiling. Empty by default.
# =============================================================================
HEAVY_MEMORY=(
    # "node.*opencode"                            # detached opencode memory leak
    # "bun .*/\\.bun/bin/omp"                     # detached OMP above threshold
    # "__omp_worker_"                             # detached OMP worker above threshold
    # "electron.*--renderer"                      # detached Electron renderer
)
HEAVY_MEMORY_MB=2000   # RSS threshold in MB

# =============================================================================
# HIGH_CPU: detached matching processes are considered when sustained %CPU
# exceeds HIGH_CPU_PCT across two samples. Live terminal trees and interactive
# browsers are always protected. When enabled, `reap top` and `reap preview`
# wait HIGH_CPU_SAMPLE_SEC for the second sample.
# =============================================================================
HIGH_CPU=(
    # "/.local/bin/agent"                          # cursor-agent main binary
    # "/cursor-agent/.*/agent"                     # cursor-agent versioned binary
    # "/cursor-agent/.*/rg"                        # cursor-agent's bundled ripgrep
    # "node.*opencode.*serve"                      # opencode serve, when not foregrounded
    # "bun .*/\\.bun/bin/omp"                     # detached OMP burning CPU
    # "__omp_worker_"                             # detached OMP worker burning CPU
)
HIGH_CPU_PCT=85           # %CPU threshold (sustained avg of 2 samples)
HIGH_CPU_SAMPLE_SEC=20    # gap between samples (interactive runs wait this long)

# =============================================================================
# DEDUPE: keep only the N newest instances of each pattern, kill older
# duplicates. Designed for MCP-server hoarding — every claude / cursor-agent
# / codex session spawns its own MCP clients (posthog, shadcn,
# @modelcontextprotocol/server-*); when the session ends they often persist
# parented to a long-lived npx wrapper, so PPID=1 detection misses them.
# Each idle MCP is small (~5-100 MB) but accumulating dozens easily eats
# 500MB+ of RAM with zero benefit.
#
# DEDUPE_KEEP must be >= 1 (safety: never zero a pattern).
# Raise it if you legitimately keep many concurrent agent sessions of the
# same kind alive (e.g., 5 claude terminals across 5 projects → KEEP=5).
# =============================================================================
DEDUPE=(
    # "mcp-remote"                                  # any MCP fetched via mcp-remote
    # "shadcn mcp"                                  # shadcn MCP server
    # "@modelcontextprotocol/server-"               # official MCP servers
    # "node.*mcp-server-"                           # third-party MCP servers
    # "convex.*mcp start"                           # Convex MCP wrapper/server
)
DEDUPE_KEEP=3

# =============================================================================
# Sweep interval (seconds). Default 600 (10 min). Lower = faster cleanup
# of leaks, slightly more CPU on the sweep itself (~100 ms × 144 sweeps/day
# at 600s = ~14 s/day total). Raise to 1800 for 30-min sweeps if you prefer
# less noise.
#
# Take effect: edit, then run `reap install` to regenerate the LaunchAgent.
# =============================================================================
REAP_INTERVAL_SEC=600

# A candidate must remain detached across repeated scheduled scans before it
# can be killed. With the default schedule, 15 minutes means at least two
# independent observations.
DETACHED_GRACE_MINUTES=15

# Graceful SIGTERM window before SIGKILL is used for surviving processes.
TERM_GRACE_SEC=3

# =============================================================================
# Other options
# =============================================================================
VERBOSE=0   # 1 = also print to stderr (useful when debugging)
