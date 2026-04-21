# agent-reaper 🪦

> Kill the zombie processes your AI coding agents leave behind.

<p align="center">
  <a href="https://developh.co">
    <img src="./assets/sponsor-developh.svg" alt="Sponsored by developh.co" width="100%">
  </a>
</p>

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS-lightgrey.svg)]()
[![shellcheck](https://github.com/tiagonrodrigues/agent-reaper/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/tiagonrodrigues/agent-reaper/actions/workflows/shellcheck.yml)

A tiny macOS tool that sweeps away the orphaned `claude`, `cursor-agent`, `codex`, `aider`, and `playwright` processes that AI-agent wrappers forget to clean up. Runs every 30 minutes in the background. Never touches an active session.

## The problem

If you live in AI-agent IDEs (T3 Code, Claude Code, Cursor Agent, Warp Agent Mode, name your poison), you've probably noticed your Mac running hot for no obvious reason. One afternoon I actually checked:

```
30  claude CLI processes (only 2 of them actually in use)
80  orphaned opencode-ai servers (I don't even use opencode)
4   zombie Playwright Chromiums from a test run on Monday
load average: 4.90 · fan spinning · battery melting
```

Agent wrappers spawn child processes and don't always reap them when you close a session, switch projects, or the IDE crashes. They pile up silently for days.

## The fix

A shell script, a LaunchAgent, and a small CLI. The LaunchAgent runs every 30 minutes and decides what to kill using three tiers:

| Tier | When it kills | Example targets |
|---|---|---|
| `ALWAYS_KILL` | Every run, unconditionally | Tools you never use that keep spawning |
| `ORPHAN_ONLY` | Only if `PPID=1` (parent died) | `claude`, `cursor-agent`, `codex`, `aider` |
| `OLD_PROCESS` | Only if older than N hours | `playwright chromium`, `puppeteer` |

The `ORPHAN_ONLY` rule is the important one. Active sessions always have their IDE or terminal as parent, so they're never candidates. Only the processes whose wrapper already died get reaped. Zero false positives in practice.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/tiagonrodrigues/agent-reaper/main/install.sh | bash
```

Or clone it and run the installer:

```bash
git clone https://github.com/tiagonrodrigues/agent-reaper.git
cd agent-reaper
./install.sh
```

The installer:
- drops the `reap` CLI into `~/.local/bin/`
- builds `~/Applications/Agent Reaper.app` (a proper signed macOS bundle, so Login Items and Activity Monitor show *Agent Reaper*, not a nameless `bash`)
- loads the LaunchAgent, which fires an initial sweep immediately

## The `reap` CLI

```
$ reap
reap v0.3.0

● scheduled    every 30 minutes via launchd
  config: 0 always-kill · 4 orphan-only · 2 stale (>2h)

recent activity
  [2026-04-21 11:29:49] Clean run, no zombies found
  [2026-04-21 11:59:50] Killed 3 (orphan (PPID=1): claude --output-format stream-json)
  ...

commands: reap preview · reap run · reap logs · reap config
```

| Command | What it does |
|---|---|
| `reap` | Status: schedule, config summary, recent activity |
| `reap preview` | Dry-run. Shows exactly what would be killed (PIDs, age, command). Kills nothing. |
| `reap run` | Kill zombies now. Also what the LaunchAgent calls every 30 minutes. |
| `reap logs [-f]` | Show recent log entries. Pass `-f` to follow. |
| `reap config` | Open `~/.config/agent-reaper/config.sh` in `$EDITOR` |
| `reap install` | (Re)install the LaunchAgent and the app bundle |
| `reap uninstall` | Remove it. Add `--purge` to also delete config and logs. |

## Preview before you reap

```
$ reap preview
reap preview (dry-run, nothing will be killed)

would kill 3 process(es), orphan (PPID=1): claude --output-format stream-json
    PID 14086   06:51         claude --output-format stream-json --verbose ...
    PID 79739   02:14         claude --output-format stream-json --verbose ...
    PID 67833   10:20         claude --output-format stream-json --verbose ...

would kill 1 process(es), stale (>2h): ms-playwright/chromium
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

Hardcoded defenses. Not configurable. They always apply:

- **Never runs as root.** Exits immediately if invoked with `EUID=0`.
- **UID-scoped.** Only processes owned by the invoking user are considered.
- **Hard blocklist.** Even if a user pattern matched them, reap refuses to kill `launchd`, `kernel_task`, `WindowServer`, `loginwindow`, `Finder`, `Dock`, `SystemUIServer`, `sshd`, login shells, anything under `/System/Library`, or reap itself.
- **Pattern sanity.** Rejects empty patterns, `*`, `.*`, or anything shorter than 4 characters.
- **Max-kill cap.** If a single rule matches more than 50 processes, the rule is aborted and logged. Something is almost certainly wrong, review manually.
- **Dry-run first.** `reap preview` shows you everything before you commit to any kills.

## How it works

**The PPID=1 trick.** On Unix, when a process's parent dies, the kernel re-parents the child to `launchd` (PID 1). A `claude` CLI whose T3 Code session died will have `PPID=1`. An active one has the IDE's helper process as parent. Perfect discriminator, zero false positives in practice.

**LaunchAgent, not cron.** macOS deprecated cron. `launchd` respects laptop sleep/wake, handles missed runs on resume, and doesn't need a login shell.

**A real .app bundle.** The LaunchAgent invokes `~/Applications/Agent Reaper.app/Contents/MacOS/AgentReaper` rather than a raw shell script. macOS uses the bundle's `Info.plist` to attribute the process, so Login Items, Activity Monitor, and the security pane show **Agent Reaper** with a proper identity. The bundle is ad-hoc signed at install time (`codesign -fs -`). Background-only, so no Dock icon and no app-switcher entry.

**Performance.** Runs with `Nice=10` and `LowPriorityIO=true`. Takes under 100ms on an M-series Mac.

## Uninstall

```bash
reap uninstall              # keep config + logs
reap uninstall --purge      # remove everything
```

## FAQ

**Will this kill my active Claude Code or Cursor session?**
No. Active sessions have their IDE as parent (`PPID ≠ 1`), so they never match the `ORPHAN_ONLY` rule. The only way an agent ends up in its crosshairs is if its parent already died, at which point it's genuinely orphaned.

**What if I actually use opencode (or anything else in `ALWAYS_KILL`)?**
Remove it from `ALWAYS_KILL` in your config, or move the pattern into `ORPHAN_ONLY` to use the safer rule.

**Does this work on Linux?**
Not yet. The script is POSIX-compatible but the scheduler (`launchd`) is macOS-only. A `systemd --user` timer equivalent is on the roadmap. PRs welcome.

**Is this safe? I'm paranoid.**
Good. Run `reap preview` once and inspect what it would do. The worst case is an orphaned agent getting killed 30 minutes earlier than it otherwise would, which is the point.

## Contributing

PRs and issues welcome. Good first targets:
- Linux support via `systemd --user`
- Patterns for more agent CLIs (Gemini, Replit Agent, etc.)
- Homebrew formula

## License

MIT. See [LICENSE](./LICENSE).

## Credits

Built by [Tiago Rodrigues](https://twitter.com/tiagoatdeveloph) ([@tiagoatdeveloph](https://twitter.com/tiagoatdeveloph)) out of frustration, after watching his Mac's fan try to achieve liftoff.

Sponsored by [developh.co](https://developh.co), a design studio, built different.
