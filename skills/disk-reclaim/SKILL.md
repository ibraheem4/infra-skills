---
name: disk-reclaim
description: Use when reclaiming disk space on a development machine. Prune regenerable caches before touching anything that holds work, and never assume a build-output directory is untracked.
---

# Disk Reclaim

## Overview

Caches hold more space than repos and carry no risk. Reclaim in risk order: regenerable data
first, working trees last. The one trap that turns this destructive is assuming every
`dist/` and `build/` directory is generated — some are committed.

## When to Use

- A machine is low on space, or a directory has grown unexpectedly
- Periodic workstation cleanup
- After abandoning a tool, framework, or experiment

**Do not use** to delete git repositories — see `safe-repo-removal`.

## Core Process

### 1. Inventory before deleting anything

Size every top-level entry including dotfiles, sort by size, and classify each as: regenerable
cache, toolchain, working tree, or unknown. Report the table. Delete nothing yet.

```sh
du -sh ~/.* ~/* 2>/dev/null | sort -h | tail -40
```

Large `du`/`find` sweeps exceed typical command timeouts — run them in the background.

### 2. Caches first — this is where the space is

Caches routinely exceed every repo on the machine combined. Use each tool's own prune command
so you do not break the tool:

```sh
npm cache clean --force        # then check ~/.npm/_npx separately — often the real bulk
uv cache clean
go clean -modcache
pnpm store prune
brew cleanup
```

Check the subdirectory breakdown before and after. A tool-level `clean` may leave the largest
subdirectory untouched.

Three of these fail in ways that look like success if you do not read the output. Measured
2026-09-10, on a machine where ~30G of the reclaim was cache:

| Command | Failure | Fix |
|---|---|---|
| `pnpm store prune` | none — but the store was **18G**, larger than every other cache combined | Run it first; it is usually the whale |
| `uv cache clean` | `Timeout (300s) when waiting for lock` if any uv process holds it — five minutes of nothing | `uv cache clean --force` |
| `bun pm cache rm` | `No package.json was found` — it needs a project, not a home directory | `cd` into any repo first |

A prune that printed an error and a prune that printed nothing are equally easy to scroll
past. Re-measure every cache afterwards rather than trusting the run.

### 3. Runtime version managers hold more than the caches do

On a long-lived dev machine these outweigh every project: pyenv 3.9G, bun 2.7G, go 2.2G,
nvm 2.1G, sdkman 1.6G, rustup 1.2G in one 2026-09-10 inventory. They are also the riskiest
thing in this skill, because deleting the wrong version breaks a repo that was working.

**Resolve aliases numerically before pruning.** `ls ~/.nvm/versions/node | tail -1` string-sorts
`v22.9.0` above `v22.20.0`, so the "newest" it reports is the wrong one — and it is the one an
alias like `default -> 22` actually points at. Ask the tool: `nvm version default`. The same
applies to pyenv's `version` file and rbenv's.

**Sweep every project root for pins before deleting a version** — `.nvmrc`, `.ruby-version`,
`.python-version`, `.sdkmanrc` — and keep the union of what they name plus what the aliases
resolve to. Then check for globally-installed packages under each version you are about to
remove; they go with it.

**A manager can be installed, hold a version file, and do nothing.** rbenv reported `3.0.2`
while `ruby` resolved to Homebrew's 2.6, because nothing ever ran `rbenv init` — the shims
directory sat on PATH behind `/usr/bin`. Test that the binary resolves to the shim, not that
the manager's directory exists. A manager in this state is pure weight: remove it, or
initialise it, but do not leave it.

⚠️ **Check the machine's own installer before removing a manager, or it comes back.** A
setup script guarded by `if [ -d "$HOME/.sdkman" ]; then echo already installed; else curl …`
treats your deletion as the signal to reinstall. Removing the directory and then running the
installer restores everything you just freed. Remove the install step in the same change.

### 4. Date-sort tool directories to find abandoned experiments

Tool state directories cluster by the day they were tried and never touched again:

```sh
for d in ~/.*; do
  [ -d "$d" ] && printf '%6s %s  %s\n' "$(du -sh "$d"|cut -f1)" "$d" \
    "$(find "$d" -type f -exec stat -f '%Sm' -t '%Y-%m-%d' {} \; 2>/dev/null | sort -r | head -1)"
done | sort -rh
```

Several directories whose newest contained file share one date is a single abandoned session.
Confirm with the owner before deleting — "unused for months" is a judgment call, not a fact.

### 5. Build artifacts — check tracked status BEFORE deleting

A blanket `find . -name dist -exec rm -rf {} +` will delete **committed** files. Some repos
ship generated tokens, type definitions, or bundles. Always check after:

```sh
git status --porcelain | grep '^ D'        # tracked files you just deleted
git checkout -- <paths>                     # restore them
```

Safer: only remove paths that are git-ignored.

```sh
git clean -nXd     # dry run — ignored files only
git clean -fXd     # execute
```

### 6. Never touch these

`~/Library`, `~/.ssh`, `~/.gnupg`, `~/.config`, agent state directories, and anything holding
credentials. Preserve the cache of any tool the owner said to keep — deleting its runtime forces
a re-download and may break it.

### 7. Fix what the deletion broke

Registries with `local_path` fields, READMEs, and layout docs may reference deleted paths.
Correct them, and validate any structured file still parses.

**Shell config is the most common dangling reference.** Removing a version manager leaves its
init block sourcing a path that no longer exists — harmless while the block is guarded, dead
weight either way, and a lie to the next reader.

🔴 **Edit the source, not the installed copy.** Where dotfiles are managed by an installer
that copies (`cp .zshrc "$HOME/.zshrc"`) rather than symlinks, an edit to `$HOME` survives
exactly until the next run. Worse, the reverse is also true and quieter: anything added
directly to the installed copy is destroyed by that run. Two instances surfaced in one
cleanup on 2026-09-10 — a Unity CLI line in `~/.zshrc` and an MCP server entry in
`~/.gemini/settings.json`, both live for weeks, neither in the repo, both due to be
overwritten. **Diff the installed copy against its source before running the installer**, and
port anything that only exists downstream.

## Common Rationalizations

| Excuse | Why It's Wrong |
|--------|---------------|
| "`dist/` is always build output" | Some repos commit it. Check `git status` for `^ D` after deleting |
| "Deleting repos frees the most space" | Caches are usually larger and carry no risk. Do those first |
| "`npm cache clean` cleared the cache" | It may leave `_npx` — check the subdirectory breakdown |
| "That directory looks unused" | Sort by newest contained file, then confirm before deleting |
| "`rm -rf` on the tool dir is the same as pruning" | Tool-native prune preserves the structure the tool expects |
| "I removed the version manager, so it's gone" | The setup script's guard is `if [ -d ... ]`. Your deletion is its install trigger |
| "`ls | tail -1` gives me the newest version" | That is a string sort. v22.9.0 outranks v22.20.0. Ask the tool |
| "The manager is installed, so it's in use" | Check the binary resolves to its shim. rbenv had a version file and did nothing |
| "I'll measure the space saved with `df`" | On APFS `df` is unreliable mid-operation. Compare `du` before and after |

## Red Flags

- Deleting before an inventory has been reported
- Any `find -delete` across repos without a `git status` check afterwards
- Reaching for working trees while multi-gigabyte caches remain
- `rm -rf` on a directory belonging to a tool the owner still uses
- Structured config edited during cleanup and never re-parsed

## Verification

- [ ] Inventory produced and classified before any deletion
- [ ] Caches pruned with tool-native commands, and subdirectory breakdown re-checked
- [ ] Every version kept is one an alias resolves to or a project pins; aliases resolved by the tool
- [ ] No removed manager is reinstalled by the machine's own setup script
- [ ] Installed dotfiles diffed against their source before the installer ran
- [ ] `git status --porcelain | grep '^ D'` run in every touched repo — zero tracked deletions
- [ ] No protected path touched
- [ ] Dangling references to deleted paths corrected; structured files re-validated
- [ ] Space reclaimed reported from `du` before/after, not `df`
