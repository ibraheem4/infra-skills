---
name: safe-repo-removal
description: Use when deleting, archiving, or relocating a git repository or working tree. Prove every commit is recoverable before removing anything.
---

# Safe Repo Removal

## Overview

Deleting a repo is only safe if re-cloning restores everything. That is a claim about five
different places work can hide, not one. This skill proves the claim before the `rm`.

## When to Use

- Cleaning up a projects directory or removing a stale checkout
- Archiving a repo, or moving one between machines or parent directories
- Any task where a directory containing `.git` is about to be deleted

**Do not use** for deleting build output, caches, or `node_modules` — see `disk-reclaim`.

## Core Process

### 1. Run all five checks

A clean `git status` is not enough. Work hides in five places:

```sh
git status --porcelain                                  # uncommitted
git log @{u}..                                          # unpushed
git stash list                                          # stashes
git worktree list                                       # worktrees
git branch --format='%(refname:short) %(upstream)'      # branches with no upstream
```

Empty on all five, or the repo is not safe to delete. Stashes are the one people miss —
they are invisible to `status`, `log`, and every branch listing.

### 2. Confirm you can actually push before assuming you can

Read access does not imply write access, and a fork is not always available:

```sh
gh api repos/OWNER/NAME --jq '{permissions, allow_forking, private, default_branch}'
```

If `push: false`, go to step 4. If `allow_forking: false`, **stop and ask** — see Red Flags.

### 3. Record where it came from, outside the directory

Before removing anything, write `path → remote URL → current SHA` to a manifest file that
will survive the deletion. Deletion is only reversible because a clone can restore it; the
manifest is what makes that possible.

```sh
printf '%-40s %s @ %s\n' "$dir" "$(git -C "$dir" remote get-url origin)" \
  "$(git -C "$dir" rev-parse --short HEAD)" >> ../REMOVED-REPOS.md
```

### 4. If work cannot be pushed, bundle it — then restore-test the bundle

```sh
git bundle create work.bundle main..my-branch
git bundle verify work.bundle          # necessary, NOT sufficient
```

`git bundle verify` only checks the bundle's internal consistency. It cannot tell you the
bundle contains what you meant. Actually restore it:

```sh
git clone <origin> /tmp/restore-test && cd /tmp/restore-test
git fetch ../work.bundle 'refs/heads/*:refs/heads/*'
git checkout my-branch
git hash-object <each-file>            # compare against the source
```

Write the restore commands next to the bundle. A bundle nobody knows how to restore is not
a backup.

### 5. Delete, then fix what the deletion broke

Search for references to the path you just removed — registries, READMEs, config files,
`local_path` fields — and correct them. A dangling pointer sends the next reader chasing a
directory that no longer exists.

## Common Rationalizations

| Excuse | Why It's Wrong |
|--------|---------------|
| "`git status` is clean, so it's pushed" | Clean tree says nothing about unpushed commits, stashes, or branches with no upstream |
| "I checked the branch I was on" | Stashes and other local branches are not on your branch |
| "`git bundle verify` passed" | That checks internal consistency only, not that the bundle holds the right commits |
| "I can just re-clone it" | Only if you recorded the remote *and* still have read access. Verify both first |
| "Forking gets around the push block" | `allow_forking: false` is a deliberate control. Mirroring history elsewhere defeats it |
| "It's just a scratch checkout" | Scratch checkouts are exactly where unpushed experiments live |

## Red Flags

- Running `rm -rf` before a manifest of remotes and SHAs exists
- Treating a push failure as a problem to route around rather than report
- A bundle created but never restore-tested
- Deleting a repo whose remote you never confirmed you can reach
- `rm -rf` reporting "Operation not permitted" on `.git/config` and leaving a `.git` skeleton —
  the delete half-failed; rerun it with the necessary permissions

## Verification

- [ ] All five checks returned empty, or their output was preserved
- [ ] `gh api` confirmed push access, or unpushed work was bundled instead
- [ ] Manifest of `path → remote → SHA` exists **outside** the deleted directory
- [ ] Any bundle was restore-tested: commits present and file hashes match the source
- [ ] Directory is fully gone — no `.git` skeleton left behind
- [ ] References to the old path (registries, docs, configs) updated
