#!/usr/bin/env bash
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/reap-fixture.XXXXXX")
fixture_pid=""
cleanup() {
    [ -n "$fixture_pid" ] && kill -KILL "$fixture_pid" 2>/dev/null || true
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$TMP_ROOT/config/agent-reaper" "$TMP_ROOT/state"
cat > "$TMP_ROOT/config/agent-reaper/config.sh" <<'CONFIG'
ALWAYS_KILL=()
ORPHAN_ONLY=()
OLD_PROCESS=("reap-fixture-ghost-9f31")
OLD_THRESHOLD_HOURS=0
HEAVY_MEMORY=()
HIGH_CPU=()
DEDUPE=()
DETACHED_GRACE_MINUTES=0
TERM_GRACE_SEC=0
VERBOSE=1
CONFIG

python3 - "$TMP_ROOT/fixture.pid" <<'PY'
import os
import sys

pid = os.fork()
if pid:
    with open(sys.argv[1], "w", encoding="utf-8") as pid_file:
        pid_file.write(str(pid))
    os._exit(0)

os.setsid()
os.execv("/bin/sleep", ["reap-fixture-ghost-9f31", "300"])
PY
fixture_pid=$(cat "$TMP_ROOT/fixture.pid")
sleep 0.1

if ! kill -0 "$fixture_pid" 2>/dev/null; then
    echo "not ok - fixture failed to start"
    exit 1
fi

XDG_CONFIG_HOME="$TMP_ROOT/config" XDG_STATE_HOME="$TMP_ROOT/state" \
    bash "$ROOT/reap.sh" run
if ! kill -0 "$fixture_pid" 2>/dev/null; then
    echo "not ok - first observation bypassed quarantine"
    exit 1
fi

echo "ok - first detached observation is quarantined"
XDG_CONFIG_HOME="$TMP_ROOT/config" XDG_STATE_HOME="$TMP_ROOT/state" \
    bash "$ROOT/reap.sh" run
sleep 0.1
if kill -0 "$fixture_pid" 2>/dev/null; then
    echo "not ok - repeatedly detached fixture survived cleanup"
    exit 1
fi

fixture_pid=""
echo "ok - repeatedly detached fixture was terminated"
