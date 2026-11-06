#!/usr/bin/env bash
# Disk cleanup of idle agent worktrees: only clean, idle, unused linked
# worktrees lose their dependency folders, and only to the (fake) Trash.
# shellcheck disable=SC1091,SC2034
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/reap-worktrees.XXXXXX")
BUSY_PID=""
cleanup() {
    [ -n "$BUSY_PID" ] && { kill "$BUSY_PID"; wait "$BUSY_PID"; } 2>/dev/null
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

export REAP_TEST_MODE=1
export XDG_CONFIG_HOME="$TMP_ROOT/config"
export XDG_STATE_HOME="$TMP_ROOT/state"
mkdir -p "$XDG_STATE_HOME/agent-reaper"
# shellcheck source=../reap.sh
source "$ROOT/reap.sh"
load_config

FAKE_TRASH="$TMP_ROOT/trash"
mkdir -p "$FAKE_TRASH"
trash_paths() {
    local p
    for p in "$@"; do
        mv "$p" "$FAKE_TRASH/$(basename "$(dirname "$p")")-$(basename "$p")" || return 1
    done
}
osascript() { :; }

fail() { echo "not ok - $*"; exit 1; }
ok() { echo "ok - $*"; }

g() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@" >/dev/null 2>&1; }

WT_ROOT="$TMP_ROOT/worktrees/project"
MAIN="$WT_ROOT/main"
mkdir -p "$MAIN"
g -C "$MAIN" init -q
printf 'node_modules\n.next\n' > "$MAIN/.gitignore"
echo hi > "$MAIN/file.txt"
g -C "$MAIN" add -A
g -C "$MAIN" commit -qm init
mkdir -p "$MAIN/node_modules/pkg"

make_wt() {
    local name="$1"
    g -C "$MAIN" worktree add -q "$WT_ROOT/$name" -b "$name"
    mkdir -p "$WT_ROOT/$name/node_modules/pkg" "$WT_ROOT/$name/.next/cache"
    head -c 65536 /dev/zero > "$WT_ROOT/$name/node_modules/pkg/index.js"
}
age_wt() {
    local gitdir
    gitdir=$(git -C "$WT_ROOT/$1" rev-parse --absolute-git-dir)
    touch -t 202601010000 "$gitdir/index" "$gitdir/HEAD" "$gitdir/logs/HEAD" 2>/dev/null
}

make_wt idle;   age_wt idle
make_wt dirty;  age_wt dirty; echo changed >> "$WT_ROOT/dirty/file.txt"
make_wt recent
make_wt busy;   age_wt busy
make_wt linked; age_wt linked
rm -rf "$WT_ROOT/linked/node_modules" "$WT_ROOT/linked/.next"
ln -s "$MAIN/node_modules" "$WT_ROOT/linked/node_modules"
(cd "$WT_ROOT/busy" && exec sleep 60) &
BUSY_PID=$!
sleep 0.5

WORKTREE_ROOTS=("$TMP_ROOT/worktrees")
WORKTREE_IDLE_DAYS=3
WORKTREE_DEPENDENCY_DIRS=(node_modules .next ../escape /)

listed=$(list_worktrees)
printf '%s\n' "$listed" | grep -qx "$MAIN" && fail "main checkout must never be listed"
[ "$(printf '%s\n' "$listed" | grep -c .)" -eq 5 ] || fail "expected 5 linked worktrees, got: $listed"
ok "only linked worktrees are listed"

DRY_RUN=1
out=$(process_worktrees)
process_worktrees >/dev/null
[ "$DISK_CLEANED" -eq 1 ] || fail "dry-run should select exactly 1 worktree, got $DISK_CLEANED: $out"
printf '%s\n' "$out" | grep -q "trash.*$WT_ROOT/idle" || fail "idle worktree not selected: $out"
printf '%s\n' "$out" | grep -q "keep.*dirty.*uncommitted changes" || fail "dirty worktree not kept: $out"
printf '%s\n' "$out" | grep -q "keep.*recent.*git activity" || fail "recent worktree not kept: $out"
printf '%s\n' "$out" | grep -q "keep.*busy.*process is running" || fail "busy worktree not kept: $out"
printf '%s\n' "$out" | grep -q "linked" && fail "symlinked node_modules must be ignored: $out"
[ -d "$WT_ROOT/idle/node_modules" ] || fail "dry-run moved files"
ok "dry-run selects only the clean, idle, unused worktree"

process_worktrees >/dev/null
[ "$DISK_CLEANED" -eq 1 ] || fail "status during dry-run reset the idle clock"
ok "scanning does not reset the idle clock"

DRY_RUN=0
process_worktrees
[ ! -e "$WT_ROOT/idle/node_modules" ] && [ ! -e "$WT_ROOT/idle/.next" ] || fail "idle deps not moved"
[ -f "$FAKE_TRASH/idle-node_modules/pkg/index.js" ] || fail "deps did not reach the Trash"
[ -f "$WT_ROOT/idle/file.txt" ] || fail "code was touched"
[ -d "$WT_ROOT/dirty/node_modules" ] && [ -d "$WT_ROOT/recent/node_modules" ] && [ -d "$WT_ROOT/busy/node_modules" ] \
    || fail "a protected worktree lost its deps"
[ -d "$MAIN/node_modules" ] || fail "main checkout touched"
[ -L "$WT_ROOT/linked/node_modules" ] || fail "symlink touched"
[ -d "$TMP_ROOT/worktrees/project/../escape" ] && fail "unsafe dependency name followed"
ok "run moves only the selected deps to the Trash"

grep -q "$WT_ROOT/idle" "$WORKTREE_HISTORY_FILE" || fail "history not written"
worktree_scan_due && fail "scan should not be due right after a run"
echo $(( $(date +%s) - 25 * 3600 )) > "$WORKTREE_STATE_FILE"
worktree_scan_due || fail "scan should be due after WORKTREE_SCAN_HOURS"
WORKTREE_ROOTS=()
worktree_scan_due && fail "scan must be off without roots"
ok "history, schedule and opt-in"

echo "all worktree tests passed"
