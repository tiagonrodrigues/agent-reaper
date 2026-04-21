#!/bin/bash
# AgentReaper.app inner executable.
# This runs as the background agent identified to macOS by the app bundle.
# install.sh renders this from the template, replacing the placeholder on the
# exec line below with the absolute path to the reap CLI found on this machine
# (e.g. ~/.local/bin/reap, /opt/homebrew/bin/reap).

exec "{{REAP_PATH}}" run "$@"
