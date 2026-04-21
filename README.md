# agent-reaper 🪦

> Kill the zombie processes your AI coding agents leave behind.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS-lightgrey.svg)]()
[![shellcheck](https://github.com/tiagonrodrigues/agent-reaper/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/tiagonrodrigues/agent-reaper/actions/workflows/shellcheck.yml)

A tiny macOS LaunchAgent that sweeps away the orphaned `claude`, `cursor-agent`, `codex`, `aider`, and `playwright` processes that AI-agent wrappers forget to clean up. Runs every 30 minutes, never touches an active session.

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

A shell script + a macOS LaunchAgent. It runs every 30 minutes with three tiers of aggression:

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

Or clone and run locally:

```bash
git clone https://github.com/tiagonrodrigues/agent-reaper.git
cd agent-reaper
./install.sh
```

That's it. The LaunchAgent is loaded, first sweep runs immediately, next in 30 min.

## Verify

```bash
# Is it scheduled?
launchctl list | grep agent-reaper

# What did it kill?
tail ~/.local/share/agent-reaper/reap.log

# Run a sweep on demand
~/.local/bin/agent-reaper.sh
```

Log output looks like:

```
[2026-04-19 21:04:15] Killed 4 process(es) — always-kill: opencode-ai/bin/.opencode
[2026-04-19 21:04:15] Killed 28 process(es) — orphan (PPID=1): claude --output-format stream-json
[2026-04-19 21:04:15] Killed 4 process(es) — stale (>2h): ms-playwright/chromium
[2026-04-19 21:04:15] === Reaped 36 process(es) ===
```

## Customize

Edit `~/.config/agent-reaper/config.sh` (seeded on first install from [`config.example.sh`](./config.example.sh)).

Add your own patterns, move tools between tiers, adjust the age threshold for stale browsers. Example:

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

## How it works

**Heuristic explained.** The reaper uses three matching strategies:

1. **PPID=1 check (`ORPHAN_ONLY`)** — On Unix, when a process's parent dies, the kernel re-parents it to `launchd` (PID 1). An `claude` CLI whose T3 Code session died will have `PPID=1`. An active one has the IDE's helper process as parent. Perfect discriminator.

2. **Elapsed time (`OLD_PROCESS`)** — For tools that should be short-lived. Playwright spawns headless browsers for tests; when a test crashes they sometimes leak. A Chromium running for > 2 hours is almost certainly dead weight.

3. **Always kill (`ALWAYS_KILL`)** — Pragmatic escape hatch. If some transitive dependency keeps spawning a daemon you don't want, put it here.

**Why a LaunchAgent instead of cron?** macOS deprecated cron. `launchd` respects laptop sleep/wake cycles, handles missed runs on resume, and doesn't need a login shell.

**Performance.** The sweep runs with `Nice=10` and `LowPriorityIO=true`. Takes < 100ms on an M-series Mac. You'll never notice it running.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/tiagonrodrigues/agent-reaper/main/uninstall.sh | bash

# Or if you cloned:
./uninstall.sh

# To also remove config and logs:
./uninstall.sh --purge
```

## FAQ

**Will this kill my active Claude Code / Cursor session?**
No. Active sessions have their IDE as parent (PPID ≠ 1), so they never match the `ORPHAN_ONLY` rule. The only way an agent ends up in `ORPHAN_ONLY`'s crosshairs is if its parent already died — at which point it's genuinely orphaned.

**What if I actually use opencode?**
Remove it from `ALWAYS_KILL` in your config. Or move the pattern into `ORPHAN_ONLY` to use the safer rule.

**Does this work on Linux?**
Not yet. The script is POSIX-compatible but the scheduler (`launchd`) is macOS-only. A `systemd --user` timer equivalent is on the roadmap — PRs welcome.

**Does this work on Apple Silicon?**
Yes. Tested on M1/M2/M3 running macOS 14+.

**Is this safe? I'm paranoid.**
Run `kill-zombies.sh` once manually and inspect the log. Edit `ALWAYS_KILL` to be empty and only use `ORPHAN_ONLY` patterns until you're comfortable. The worst case is an orphaned agent getting killed 30 minutes earlier than it otherwise would — which is the point.

## Contributing

PRs and issues welcome. Good first targets:
- Linux support via `systemd --user`
- Patterns for more agent CLIs (Gemini, Replit Agent, etc.)
- A `--dry-run` mode for the script itself
- Homebrew formula

## License

MIT. See [LICENSE](./LICENSE).

---

Made out of frustration by [@tiagoatdeveloph](https://twitter.com/tiagoatdeveloph) after watching my Mac's fan try to achieve liftoff.
