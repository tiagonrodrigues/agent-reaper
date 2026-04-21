# agent-reaper 🪦

> Kill the zombie processes your AI coding agents leave behind.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS-lightgrey.svg)]()
[![shellcheck](https://github.com/tiagonrodrigues/agent-reaper/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/tiagonrodrigues/agent-reaper/actions/workflows/shellcheck.yml)

A tiny macOS LaunchAgent + CLI that sweeps away the orphaned `claude`, `cursor-agent`, `codex`, `aider`, and `playwright` processes that AI-agent wrappers forget to clean up. Runs every 30 minutes, never touches an active session.

---

## The problem

If you live in AI-agent IDEs (T3 Code, Claude Code, Cursor Agent, Warp Agent Mode, etc.), you've probably noticed your Mac getting warmer than it should. One day I checked:

```
30  claude CLI processes (2 of them actually in use)
80  orphaned opencode-ai servers (I don't even use opencode)
4   zombie Playwright Chromiums from a test run on Monday
—
load average: 4.90 · fan spinning · battery melting
```

Agent wrappers spawn child processes and don't always reap them when you close a session, switch projects, or the IDE crashes. They pile up silently for **days**.

## The fix

A shell script + LaunchAgent + tiny CLI. Runs every 30 minutes with three tiers of aggression:

| Tier | When to kill | Example targets |
|---|---|---|
| `ALWAYS_KILL` | Every run, unconditionally | Tools you never use that keep spawning |
| `ORPHAN_ONLY` | Only if `PPID=1` (parent died) | `claude`, `cursor-agent`, `codex`, `aider` |
| `OLD_PROCESS` | Only if older than N hours | `playwright chromium`, `puppeteer` |

The `ORPHAN_ONLY` rule is the key. **Active sessions always have their IDE/terminal as parent** — they're never candidates. Only the processes whose wrapper already died get reaped. Zero false positives in practice.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/tiagonrodrigues/agent-reaper/main/install.sh | bash
```

Or clone and install locally:

```bash
git clone https://github.com/tiagonrodrigues/agent-reaper.git
cd agent-reaper
./install.sh
```

That's it. `reap` goes to `~/.local/bin/`, LaunchAgent gets loaded, first sweep runs immediately.

## The `reap` CLI

```
$ reap
reap v0.2.0

● scheduled    every 30 minutes via launchd
  config: 0 always-kill · 4 orphan-only · 2 stale (>2h)

recent activity
  [2026-04-21 11:29:49] Clean run — no zombies found
  [2026-04-21 11:59:50] Killed 3 (orphan (PPID=1): claude --output-format stream-json)
  ...

commands: reap preview · reap run · reap logs · reap config
```

| Command | What it does |
|---|---|
| `reap` | Status — schedule, config summary, recent activity |
| `reap preview` | **Dry-run.** Show exactly what would be killed (PIDs, age, command) — kills nothing |
| `reap run` | Kill zombies now (also invoked by the LaunchAgent every 30 min) |
| `reap logs [-f]` | Show recent log entries (`-f` to follow) |
| `reap config` | Open `~/.config/agent-reaper/config.sh` in `$EDITOR` |
| `reap install` | (Re)install the LaunchAgent |
| `reap uninstall` | Remove it (add `--purge` to also delete config + logs) |

## Preview before you reap

```
$ reap preview
reap preview (dry-run — nothing will be killed)

would kill 3 process(es) — orphan (PPID=1): claude --output-format stream-json
    PID 14086   06:51         claude --output-format stream-json --verbose ...
    PID 79739   02:14         claude --output-format stream-json --verbose ...
    PID 67833   10:20         claude --output-format stream-json --verbose ...

would kill 1 process(es) — stale (>2h): ms-playwright/chromium
    PID 16987   1-22:15:32    chrome-headless-shell --disable-field-trial-config ...

would reap 4 process(es)  (run 'reap run' to do it)
```

## Customize

```bash
reap config
```

…opens `~/.config/agent-reaper/config.sh` in your `$EDITOR`. Move patterns between tiers, add your own, adjust the stale threshold:

```bash
ALWAYS_KILL=(
    "opencode-ai/bin/.opencode"     # I don't use opencode
)

ORPHAN_ONLY=(
    "claude --output-format stream-json"
    "cursor-agent.*stream"
    "codex.*--output-format"
    "aider.*--stream"
    "my-custom-agent --daemon"      # your own
)

OLD_PROCESS=(
    "ms-playwright/chromium"
    "puppeteer.*chromium"
)
OLD_THRESHOLD_HOURS=2
```

## Safety

Hardcoded defenses, not configurable — they always apply:

- **Never runs as root.** Exits immediately if invoked with `EUID=0`.
- **UID-scoped.** Only processes owned by the invoking user are considered.
- **Hard blocklist.** Even if a user pattern matched them, reap refuses to kill `launchd`, `kernel_task`, `WindowServer`, `loginwindow`, `Finder`, `Dock`, `SystemUIServer`, `sshd`, login shells, anything under `/System/Library`, or reap itself.
- **Pattern sanity.** Rejects empty patterns, `*`, `.*`, or patterns shorter than 4 characters.
- **Max-kill cap.** If a single rule matches > 50 processes, the rule is aborted and logged. Something is almost certainly wrong — review manually.
- **Dry-run first.** `reap preview` shows you everything before you commit to any kills.

## How it works

**The PPID=1 trick.** On Unix, when a process's parent dies, the kernel re-parents the child to `launchd` (PID 1). A `claude` CLI whose T3 Code session died will have `PPID=1`. An active one has the IDE's helper process as parent. Perfect discriminator — zero false positives in practice.

**LaunchAgent, not cron.** macOS deprecated cron. `launchd` respects laptop sleep/wake cycles, handles missed runs on resume, and doesn't need a login shell.

**Performance.** Runs with `Nice=10` and `LowPriorityIO=true`. Takes < 100ms on an M-series Mac.

## Uninstall

```bash
reap uninstall              # keep config + logs
reap uninstall --purge      # remove everything
```

## FAQ

**Will this kill my active Claude Code / Cursor session?**
No. Active sessions have their IDE as parent (PPID ≠ 1), so they never match the `ORPHAN_ONLY` rule. The only way an agent ends up in `ORPHAN_ONLY`'s crosshairs is if its parent already died — at which point it's genuinely orphaned.

**What if I actually use opencode (or anything else in `ALWAYS_KILL`)?**
Remove it from `ALWAYS_KILL` in your config, or move the pattern into `ORPHAN_ONLY` to use the safer rule.

**Does this work on Linux?**
Not yet. The script is POSIX-compatible but the scheduler (`launchd`) is macOS-only. A `systemd --user` timer equivalent is on the roadmap — PRs welcome.

**Is this safe? I'm paranoid.**
Run `reap preview` once and inspect what it would do. The worst case is an orphaned agent getting killed 30 minutes earlier than it otherwise would — which is the point.

## Contributing

PRs and issues welcome. Good first targets:
- Linux support via `systemd --user`
- Patterns for more agent CLIs (Gemini, Replit Agent, etc.)
- Homebrew formula

## License

MIT. See [LICENSE](./LICENSE).

---

Made out of frustration by [@tiagoatdeveloph](https://twitter.com/tiagoatdeveloph) after watching my Mac's fan try to achieve liftoff.
