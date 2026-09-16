---
name: find-hidden-services
description: Use when a background process keeps running, respawns after being killed, or you need a full inventory of what starts automatically on a machine. Enumerates every spawner class, not just the process list.
---

# Find Hidden Services

## Overview

A process that comes back after you kill it means you found one spawner, not all of them.
A single binary can be launched by launchd, a browser native-messaging host, and an MCP client
config simultaneously — closing one does nothing about the others. This skill enumerates every
spawner class before touching anything.

## When to Use

- A process reappears with a new PID after being killed
- Auditing what starts automatically at login or on demand
- Something is holding the machine awake, holding a port, or writing logs with no obvious owner
- Before concluding "nothing is running"

**Do not use** to stop services — enumeration is read-only. Stopping is a separate, approved step.

## Core Process

### 1. Enumerate every spawner class

Checking `ps` alone will mislead you. Each of these launches processes independently:

| Class | Where to look |
|---|---|
| launchd (user) | `~/Library/LaunchAgents/*.plist` |
| launchd (system) | `/Library/LaunchAgents/`, `/Library/LaunchDaemons/` |
| Loaded jobs | `launchctl list \| grep -v com.apple` |
| Browser native hosts | `~/Library/Application Support/*/NativeMessagingHosts/*.json` |
| MCP client configs | `~/.codex/config.toml`, `claude_desktop_config.json`, `~/.claude.json` |
| Scheduled | `crontab -l`, `at -l` |
| Login items | System Settings → General → Login Items |

Grep every one of these for the **binary path**, not the service name. The same binary appears
under different labels in different configs.

### 2. Establish what is actually exposed and held

```sh
lsof -nP -iTCP -sTCP:LISTEN     # listening ports — note any bound to *: not 127.0.0.1
pmset -g assertions             # what is preventing sleep
```

A port on `*:PORT` is reachable from the local network, not just localhost. Say so explicitly.

### 3. Read the plist before stopping anything

```sh
plutil -p ~/Library/LaunchAgents/<label>.plist
```

`KeepAlive` and `ThrottleInterval` tell you the respawn behavior — how long to wait in step 5.
`ProgramArguments` gives you the binary path to grep for in step 1.

### 4. Stop each spawner at its own layer (requires approval)

Stopping services is a consequential action. Get explicit approval naming the exact services,
then close each layer:

```sh
launchctl bootout gui/$(id -u)/<label>       # stops AND unloads; kills the process tree
mv ~/Library/LaunchAgents/<label>.plist <disabled-dir>/   # move, never delete
rm <native-messaging-manifest>.json          # back it up first
# delete the mcp_servers entry from each client config — back up, then re-validate the file parses
```

Always **move or back up** rather than delete. The config is the only record of how the service
was set up.

### 5. Verify with a method that cannot lie to you

Wait longer than `ThrottleInterval`, then re-check. Three traps:

- `grep`-ing `ps` output matches **your own shell command**. Use `pgrep -fl`, or `pmset`/`lsof`.
- Orphaned `caffeinate` children outlive their parent. `pmset -g assertions` is authoritative.
- Sandboxed shells may block `ps` entirely ("sysmond service not found") — that is not proof of absence.

## Common Rationalizations

| Excuse | Why It's Wrong |
|--------|---------------|
| "I killed the process" | launchd `KeepAlive` restarts it within seconds |
| "I removed the launchd plist, so it's gone" | Native-messaging hosts and MCP configs are separate spawners |
| "`ps` shows nothing" | Your grep may have matched its own shell, or the sandbox blocked `ps` |
| "It's only bound to a port locally" | Check for `*:` versus `127.0.0.1:` — they are very different |
| "Nothing is holding the machine awake" | Verify with `pmset -g assertions`, not by looking at `ps` |
| "I'll just delete the config" | Then nobody can re-enable it. Move it to a disabled directory |

## Red Flags

- A process whose age is always a few seconds — it is being respawned, not running
- Process count for one binary that grows over time
- Killing something and not re-checking after the throttle interval
- Deleting a plist or MCP entry without a backup
- Editing a TOML/JSON config without re-parsing it afterwards

## Verification

- [ ] Every spawner class in step 1 enumerated, and grepped by binary path
- [ ] Plist read for `KeepAlive` / `ThrottleInterval` before stopping
- [ ] Configs backed up before edit, and re-validated as parseable after
- [ ] Re-checked after waiting longer than the throttle interval — no new PIDs
- [ ] Confirmed via `pgrep`/`lsof`/`pmset`, not a `grep` of `ps` that can match itself
- [ ] Formerly-open ports confirmed closed
