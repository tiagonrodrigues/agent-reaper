#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/reap-classifier.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

export REAP_TEST_MODE=1
export XDG_CONFIG_HOME="$TMP_ROOT/config"
export XDG_STATE_HOME="$TMP_ROOT/state"
# shellcheck source=../reap.sh
source "$ROOT/reap.sh"
load_config
DRY_RUN=1
DETACHED_GRACE_MINUTES=15

FAKE_FIRST_SEEN=""
process_command() {
    case "$1" in
        101) echo "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper --type=renderer" ;;
        201) echo "node /tmp/node_modules/.bin/mcp-server-posthog" ;;
        202) echo "bun /Users/test/.bun/bin/omp" ;;
        301) echo "/Users/test/.bun/install/global/node_modules/agent-browser/bin/agent-browser-darwin-arm64" ;;
        401) echo "node /tmp/orphaned-mcp-server" ;;
        601) echo "/bin/zsh -l" ;;
        *) echo "" ;;
    esac
}
process_activity_row() {
    case "$1" in
        101) echo "1 101 ??" ;;
        201) echo "202 201 ??" ;;
        202) echo "1 202 ttys007" ;;
        301|401|601) echo "1 $1 ??" ;;
        *) echo "" ;;
    esac
}
has_live_child() {
    [ "$1" = "301" ]
}
candidate_signature() {
    echo "sig-$1"
}
candidate_first_seen() {
    [ -n "$FAKE_FIRST_SEEN" ] && echo "$FAKE_FIRST_SEEN"
}
remember_candidate() {
    :
}

failures=0
assert_status() {
    local expected="$1" pid="$2" mode="$3" label="$4"
    local decision status
    decision=$(classify_candidate "$pid" "$mode")
    status="${decision%%$'\t'*}"
    if [ "$status" != "$expected" ]; then
        printf 'not ok - %s (expected %s, got %s: %s)\n' "$label" "$expected" "$status" "$decision"
        failures=$((failures + 1))
    else
        printf 'ok - %s\n' "$label"
    fi
}

assert_status protected 101 cpu "interactive Chrome renderer is never killable"
assert_status protected 201 stale "MCP owned by a live terminal ancestor is protected"
assert_status protected 301 stale "agent-browser daemon with a live browser child is protected"
assert_status protected 601 always "shell blocklist outranks ALWAYS_KILL"
assert_status protected 999 stale "vanished process is ignored"
assert_status quarantine 401 stale "new detached process enters quarantine"

FAKE_FIRST_SEEN=$(($(date +%s) - 901))
assert_status kill 401 stale "repeated detached observation becomes killable"
FAKE_FIRST_SEEN=""
assert_status kill 401 always "explicit ALWAYS_KILL bypasses quarantine only"

filtered=$(sanitize_pids always "101 201 401" 2>/dev/null)
if [ "$filtered" != "401" ]; then
    printf 'not ok - sanitizer keeps only the safe kill candidate (got %s)\n' "$filtered"
    failures=$((failures + 1))
else
    printf 'ok - sanitizer keeps only the safe kill candidate\n'
fi

TERM_GRACE_SEC=3
KILL_CALLS=""
kill() {
    KILL_CALLS="${KILL_CALLS}|$*"
    [ "${1:-}" = "-0" ] && return 1
    return 0
}
sleep() {
    KILL_CALLS="${KILL_CALLS}|sleep $*"
}
terminate_pids "401"
case "$KILL_CALLS" in
    *"|-TERM 401|sleep 3"*) printf 'ok - termination starts with SIGTERM and grace period\n' ;;
    *)
        printf 'not ok - graceful termination sequence (got %s)\n' "$KILL_CALLS"
        failures=$((failures + 1))
        ;;
esac
case "$KILL_CALLS" in
    *"-KILL"*)
        printf 'not ok - SIGKILL used after clean SIGTERM\n'
        failures=$((failures + 1))
        ;;
    *) printf 'ok - SIGKILL skipped after clean SIGTERM\n' ;;
esac

if [ "$failures" -ne 0 ]; then
    printf '%d classifier test(s) failed\n' "$failures"
    exit 1
fi
printf 'all classifier tests passed\n'
