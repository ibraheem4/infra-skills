---
name: local-bringup
description: Use when asked to clone a repo and run it, get an app running locally, bring up a stack side by side, resume or re-run a stack after Docker was quit or the dev servers were killed, re-run from scratch after cleaning Docker, or when a fresh clone will not start. Derives the pinned toolchain, resolves port and database collisions, decides Docker vs host, verifies with a real request and a screenshot, and writes the traps down.
---

# Local bring-up

## Overview

Take a repo from cold clone to an app you have *seen* working, and leave behind enough that
the next person does not rediscover the same traps. The bar for "it runs" is a status code
and a screenshot, not a log line.

## Profile

Per-repo stacks and this machine's defaults come from a profile, never from this skill.
Resolve one first: `~/<workspace>/.claude/workspace.config.md` — the workspace the caller
named, or the single match of `~/*/.claude/workspace.config.md`. Several matches: ask which.
None: say which keys are needed and stop.

| Key | Used for |
|---|---|
| `{{machine_postgres}}` | the machine's default Postgres, used only when a repo has no opinion |
| `{{stacks}}` | per-repo ports, databases and bring-up notes — authoritative over the default |

## When to Use

- "Clone this and run it locally", "now get it running", "run the app locally"
- "I completely cleaned Docker, run it from scratch"
- Running two branches/stacks at once
- A fresh clone that boots into an error

- Resuming a stack after Docker Desktop was quit or the dev servers were killed

**Not for** a project that is already running and only needs a process restarted — though
§3's traps still apply when a resume misbehaves.

## 1. Read before you run

In this order, and do not skip to `install`:

| Read | For |
|---|---|
| `README.md` | quickstart, and any section flagged 🔴 or ⚠️ — those are scar tissue |
| `CLAUDE.md` / `AGENTS.md` | repo rules that override defaults |
| `.env.example` | what must be set, and what fails *loudly* if unset |
| `package.json` | `packageManager`, `engines`, the actual script names |
| `.node-version` / `.nvmrc` | the version it was really built on |
| lockfile | picks the package manager. Never introduce a second one |
| `compose*.yml`, `Dockerfile` | whether a supported container path already exists |

## 2. Docker or host

Prefer **Docker** when the toolchain pins are load-bearing or the app needs services.
Prefer **host** when it is a plain app whose pins match what is installed.

🔴 `packageManager: pnpm@11.x` implies **Node >= 22.13** — pnpm 11 loads `node:sqlite`.
A host on the wrong Node major fails with `ERR_UNKNOWN_BUILTIN_MODULE`, which reads like
a corrupt install. Pinning the package manager pins Node. Check both pins agree.

If you add a container, these four are not optional:

- `-H 0.0.0.0` on the dev server. Bound to loopback inside a container the published
  port maps to nothing, and it reads as "the server never started".
- `node_modules` as a **named volume**, never shared with the host — platform binaries
  (esbuild, sharp) are resolved at install time and a macOS binary aborts under linux.
- The framework build dir (`.next`, `dist`) as a **named volume**.
- A polling watcher (`WATCHPACK_POLLING=true` or `usePolling`) — Docker Desktop does not
  deliver inotify for host edits, and without it the server runs but never rebuilds.

## 3. Environment traps

Check these *before* concluding something is broken:

- 🔴 **Postgres: the repo's own choice wins — read it before assuming a port.** A repo may
  deliberately run its own version in Docker on a non-default port precisely so it misses the
  machine instance, with a `scripts/db-local.sh`-style no-Docker fallback; pointing it at the
  default port breaks it. `{{stacks}}` records each repo's choice. Only when a repo has no
  opinion does `{{machine_postgres}}` apply — and the `psql` on PATH may be a different major
  than the running server, so `psql --version` misleads. Never start a second version to
  satisfy a guess — check `docker compose ps` and the service manager first.
- 🔴 **Ports are contended.** Enumerate first: `docker ps --format '{{.Names}}\t{{.Ports}}'`
  and `lsof -nP -iTCP:<port> -sTCP:LISTEN`. `:3000` is usually held. Take the port the repo's
  own dev script names; if it collides, change the publish, not the repo.
- 🔴 **A sandboxed runtime denies more than the network.** The container socket and
  `.git/config` writes are commonly blocked, so `docker ps` fails on permissions and
  `git branch -m` half-succeeds — the ref renames, the config write fails, and the branch is
  left with no tracking at all. `git commit`, `merge` and `rebase` do not touch the config.

⚠️ Several results that look like breakage here are not. A closed port, zero rows, hundreds
of test failures, a dev server 500ing after a build — each has a benign cause that reads as a
crash. See the `agent-skills:false-verification-signals` skill before acting on any of them.

## 4. Bringing up a multi-app stack

`{{stacks}}` is authoritative for ports, databases and per-repo notes. Read it first, then
work through the five things that are specific to a stack rather than to a repo:

**Count the apps before trusting the docs.** A README, `CLAUDE.md` and the dev scripts
routinely cover only the pair someone last worked on. List `apps/*` and check each for its
own `dev` script. Where every app has one but the root has a single `dev:api`, what is missing
is **root orchestration**, not per-app support — launch the others from their own directories
rather than concluding they cannot run.

🔴 **A hardcoded `PORT` in one dev script collides with every reuse of it.** Where
`dev:<app>` pins `PORT` and `APP_URL`, reusing it for a sibling service takes down the first
one. Override `PORT`, `APP_URL`, `CORS_ORIGIN` and any self-URL before starting the sibling,
and expect its secret to live under a separate name.

⚠️ **Check whether migrations run on boot.** A `RUN_MIGRATIONS` that defaults to `false` means
they never do. Compare the migrations table against the migration files on disk rather than
assuming the schema is current.

⚠️ **Prefer an existing dev auth bypass to an interactive invite.** Where the documented
setup path is "accept an invite in a browser", that is interactive *and* writes to shared
team cloud state, and it is usually unnecessary — a seeded org in a surviving compose volume
plus a bypass flag reaches an authed screen with no round-trip. `{{stacks}}` records the org
id where one exists. Confirm it still exists first: a bypass fails closed against a stale id,
so a green run would prove nothing.

🔴 **Local green ≠ prod green** for anything touching auth or a route matcher.

**Read a local database's counts as scoped, never global.** Where the test suite shares the
dev database and nothing tears it down, aggregate counts measure fixture volume — see the
`agent-skills:false-verification-signals` skill.

## 5. Env

Copy the example, then fill only what the app actually requires. If it fails loudly on a
missing value, **that is the feature** — do not paper over it with a default.

🔴 Never invent a plausible-looking value for anything priced, signed, or customer-facing.
Use an obviously-fake placeholder so a wrong revert shows as wrong. Never commit a real
one — check `git check-ignore` on the env file before you finish.

## 6. Verify — the bar is a screenshot

"Done" means you ran something and read the output. Include the command and the result.
"It's running" is not a claim you may make from logs alone.

1. HTTP status on **every** top-level route, not just `/`.
2. A screenshot of the real UI — never infer UI from code:
   `"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless --disable-gpu \
     --window-size=1440,1600 --screenshot=out.png --virtual-time-budget=12000 <url>`
   then read the image back.
3. Typecheck and tests for anything with logic, run **in the same environment** the app
   runs in. Report the counts. 🔴 In a turborepo, pass `--force` — a cached summary replays
   another checkout's logs and counts in milliseconds. See the `worktree-pr` skill.
4. If you added hot reload, prove it: edit a string, curl for it, revert, curl again.
5. **Name any check you skipped.** Don't let silence imply green. If part of the bring-up
   is blocked, finish everything else and say exactly what is left and why.

🔴 Never edit a test, disable a lint rule, or loosen a type to make a check pass.

## 7. Write it down, on a branch

Work on a worktree/branch, never on `main` — see the `worktree-pr` skill.

Leave a `docs/local-dev.md` covering: the commands, **why** the container exists at all,
and a short table of the things that look optional and are not. Record only what cost
something to learn. If the repo says documentation belongs in Outline, follow that — but
`README.md` and a local-dev runbook are conventionally repo-resident; ask before moving.

## Never

- Never claim it runs without a status code and a screenshot in the same message.
- Never add a second package manager or a second Postgres version. The lockfile picks the
  package manager; existing config picks the runner.
- Never use a deploy or a CI run as the test loop. Iterate locally.
- Never edit a test, disable a lint rule, or loosen a type to get a green check.
- Never leave a real credential in a file you created, and never paste one into a summary.
- Never weaken an auth, permission or tenant-isolation gate to make something work locally.
- Work on a branch, never `main` — see the `worktree-pr` skill.

## Common Rationalizations

| Excuse | Why It's Wrong |
|---|---|
| "It compiled, so it runs" | You have not opened it. Status code and screenshot, or it is not done |
| "The port is closed, the service is down" | Only if your probe was allowed to reach it |
| "I'll just add the Postgres version it wants" | Now local data is split across clusters, one of them stopped |
| "The README's setup path is the only way in" | An interactive invite that writes to shared cloud state is rarely required to see an authed screen |
| "The dev server died" | A build may have rewritten what it was serving, or restarted every watcher |

## Verification

- [ ] Every top-level route returned a status code, not just `/`
- [ ] A screenshot of the real UI was captured and read back
- [ ] Typecheck and tests ran in the same environment the app runs in, counts reported
- [ ] Cache disabled on any run being used as verification
- [ ] Every check skipped is named
- [ ] No real credential was written, and the env file is confirmed git-ignored
