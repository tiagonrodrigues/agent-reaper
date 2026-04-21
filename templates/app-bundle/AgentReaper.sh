#!/bin/bash
# AgentReaper.app inner executable.
# This runs as the background agent identified to macOS by the app bundle.
# The actual logic lives in ~/.local/bin/reap (installed by install.sh).

exec "$HOME/.local/bin/reap" run "$@"
