---
name: pr-preview-environments
description: Use when building, operating, or debugging per-PR ephemeral preview environments on AWS driven by GitHub Actions — label-gated spin-up, an isolated database per PR, automatic teardown, OIDC deploy roles, and cost caps. Covers the OIDC trust split that keeps a PR-triggered role from becoming account admin, the deploy step order that decides which image's migrations run, the teardown that reports success while orphaning billable resources, and the IAM action names that do not match the operation they perform.
---

# Per-PR Preview Environments (AWS + GitHub Actions)

## Overview

A preview environment lets a reviewer click an unmerged branch. Getting there is mostly not
the deploy — it is four questions that each have a wrong answer that looks right:

1. **What triggers it?** A label, and `pull_request` rather than `workflow_dispatch`.
2. **What is isolated?** The database, or previews corrupt the environment they borrow.
3. **What can the PR's credentials do?** Bounded, or a preview is an account takeover.
4. **What destroys it, and can that lie?** An act, not a timer — and yes, it can lie.

This skill is the shape that works and the specific way each part fails.

## When to Use

- Standing up per-PR preview environments on ECS, Lambda, or S3+CloudFront
- Debugging one: a slot that half-exists, bills after teardown, or won't authenticate
- Reviewing any `pull_request`-triggered workflow that assumes an AWS role
- Auditing an IAM role a PR author can influence

**Do not use** for a shared long-lived environment (staging, prod) — the trust model is
different and simpler. For branch/PR mechanics see `agent-skills:pr-lifecycle`.

## Core Process

### 1. One slot per PR, every name derived from the number

`pr-<number>` as the slot id, with every resource name, hostname, database name and image
tag derived from it — in the workflow *and* in the IaC, off the same variable, so the two
cannot drift.

No pool, no claiming, no queue. A pool exists only to work around per-slot setup someone has
to do by hand; remove that (step 5) and the pool has no reason to exist.

### 2. Isolate the database, and make its NAME the safety gate

A preview sharing the real database is not a preview — the branch's migrations run on boot
and stay after the preview is gone. Additive migrations survive that; a rename, drop or
re-type breaks the deployed default branch the moment the preview starts.

**The quieter failure, which is worse.** Migrators that apply "where version > last applied"
compare a timestamp, not a hash. A preview branch carrying a *higher* timestamp raises the
database's high-water mark, and every lower-stamped migration merged afterwards is skipped
**permanently and silently**. Have the migrator refuse to boot when the journal names a
migration the database never recorded — that turns a 500 days later into a failed deploy now.

So: one database per slot, `<app>_<slot>`. And gate every write-fixtures / drop-database path
on **the database's name**, via one exported predicate shared by the seeder and the dropper:

```ts
const SLOT_DATABASE = /^myapp_pr_[0-9]+$/          // anchored, no wildcards
export function slotDatabase(url: string | undefined): string | null {
  if (!url) return null
  let name: string
  try { name = decodeURIComponent(new URL(url).pathname.replace(/^\//, '')) }
  catch { return null }
  return SLOT_DATABASE.test(name) ? name : null
}
```

Why the name and not a `PREVIEW=true` flag: a flag can be set on the wrong service, and the
name is *the thing actually being written to*. Every real environment is then safe by
construction, with nothing to remember. Three rules:

- **Anchored, every accepted form spelled out.** Not a wildcard.
- **Decode before matching**, or a percent-encoded name slips past a check it should fail.
- **`undefined` and unparseable answer the same as "no".** Both callers ask "is it safe to
  write fixtures here?", and an app booted with no database URL reaches this at startup —
  throwing turns a fixture check into a production boot crash.

Every place that defines "what is a slot" must agree: the workflow, the IaC name derivation,
the auth forwarder's pattern, and this predicate. List them in a comment on the predicate;
they drift otherwise.

### 3. Create and migrate the database from inside the VPC

If the database is in a private subnet, neither a laptop nor a CI runner can reach it, so IaC
cannot create it — a Terraform `postgres` provider that cannot connect fails the whole plan,
not just that resource.

Run a **one-off container task in the VPC** instead (ECS `run-task` or equivalent) using the
application image, which already carries the migration code. Idempotent, so retries are free.
Keep `ensureDatabase` out of the app's own `runMigrations`, or a typo'd URL plus a privileged
role creates a database on startup.

Check the connecting role actually has `CREATEDB` (`select rolcreatedb from pg_roles where
rolname = current_user`) rather than assuming either way.

### 4. Step order in the deploy — this is not stylistic

```
build + push image
  → register task definition (image swapped only)      ← must precede the next step
    → run-task: create + migrate the slot database     ← must precede the roll
      → roll the service onto the new revision by ARN
        → run-task: seed fixtures (non-fatal)
          → build the client bundle against THIS slot's API, verify, upload
```

🔴 **Register the task definition before the migration task.** `run-task` takes a task
definition; the service still points at the *outgoing* one until the roll. Migrate from the
running revision and you apply the **outgoing image's** migrations — so a PR's own migrations
land only on its second deploy, and a brand-new slot silently migrates to the default
branch's schema while serving the branch's code.

🔴 **Migrate before rolling.** A task booting against a database that does not exist yet gets
reverted by the deployment circuit breaker, and the cause reads like an image problem.

🔴 **Roll by task-definition ARN, never a bare `--force-new-deployment`** — that re-pulls
whatever image the *current* task definition names, and silently no-ops if it was ever
hand-pinned to a SHA tag.

⚠️ **If the client bundle bakes in the API origin at build time, assert it.** A stale bundle
talks to another slot's API, which presents as a data bug, not a deploy bug. One `grep` over
`dist/` for this slot's hostname before uploading.

⚠️ **If IaC replaces the task definition, the image reverts to the IaC default** (often
`latest`). `ignore_changes = [task_definition]` stops the tool *noticing* a deploy's image; it
does not stop a *replacement* from reverting it.

Two fixes, and the second is the one that lasts:

1. Make the automated path always follow an apply with a deploy — if the deploy job runs
   unconditionally after the provision job, CI can never land in this state, and the whole
   exposure collapses to hand-run applies.
2. Then remove the hand-run apply as a path at all: wrap it in `apply-slot.sh <slot>` that
   reads the running image, applies, and rolls the service back onto that image if the apply
   moved it. Documenting "remember to redeploy" does not survive contact with a hurry.

🔴 **A wrapper like that needs a credentials precheck before it reads current state.**
Without one, absent credentials make the "what is running now?" call fail, which reads as
"nothing is running — nothing to preserve", and the restore is silently skipped. The
protection is then off in exactly the situation where you cannot tell it is off. "I could not
reach the API" and "there is nothing there" must never give the same answer — a rule that
generalises well past this script.

### 5. Solve the auth callback once, not per PR

Most IdPs keep redirect URIs dashboard-only, with no wildcard and no API. A per-PR callback
host therefore cannot be allowlisted automatically — which is the real reason teams reach for
a fixed pool of pre-allowlisted slots.

Instead: allowlist **one** forwarder host, forever, and carry the slot in the OAuth `state` as
`<slot>.<nonce>`. A tiny edge function (CloudFront Function at viewer-request, Lambda@Edge, or
a worker) parses it and 302s to the right slot.

🔴 **The open-redirect rule is the entire security argument.** `state` is user-influenceable,
so the function must **never redirect to a URL found in the state**. It extracts a slug, tests
it against a strict anchored pattern, and **constructs** the host from it; a slug that fails
the pattern gets a 400, never a redirect. The worst an attacker achieves is delivering a code
to a real slot, which rejects it — the nonce won't match that slot's own cookie.

### 6. Split the OIDC roles, and bound the one that provisions

🔴 **Never widen an existing admin deploy role's trust to `pull_request`.** `pull_request`
workflows run the workflow file **from the PR head**, so trusting that subject on an
admin-capable role means any PR can edit the workflow into arbitrary cloud access. The
subjects differ, and that is the load-bearing detail:

```
repo:<org>/<repo>:ref:refs/heads/main   ← the existing deploy role
repo:<org>/<repo>:pull_request          ← what a preview run presents
```

Split by what the trigger is allowed to be:

| Role | Trusted for | Scope |
|---|---|---|
| deploy | `pull_request` | image push, task-def register, service update on `<prefix>-*`, `PassRole` for that service's roles, bucket sync, cache invalidation |
| provision | `pull_request` | create the slot's infrastructure — **boundary-constrained** |
| teardown | `refs/heads/main` | destroy a slot. A delete-event or dispatch run is on the default branch, so a PR cannot assume it |

**Provisioning from a PR requires an IAM permissions boundary**, because the role needs
`iam:CreateRole` and whoever opens a PR controls what it runs. Effective permissions are the
**intersection** of a role's policies and its boundary, so a created role cannot exceed the
boundary however its policy is written:

- `iam:CreateRole` only on the slot name prefix, and only with
  `Condition: StringEquals { iam:PermissionsBoundary: <boundary arn> }`
- explicit `Deny` on `iam:DeleteRolePermissionsBoundary`, `iam:CreateUser`,
  `iam:CreateAccessKey`, `iam:UpdateAssumeRolePolicy`, `sts:AssumeRole`
- re-attaching a boundary allowed only when it is *that* boundary
- the boundary policy itself managed by an operator, never by CI

⚠️ **Do not boundary-condition `iam:TagRole`** — it carries no `iam:PermissionsBoundary`
context key, so the condition can never match and the statement is dead. Condition
`CreateRole` only.

⚠️ **Put the two roles in separate JOBS, not separate steps.** Credential-configure actions
overwrite the environment, so a deploy step running while the provisioning role is still
active silently holds IAM-create rights it has no business holding.

⚠️ **Share action lists between roles split by service, not as one flat list.** A flat shared
list forces `resources = ["*"]` on everything in it — which is how a destroy action ends up
unscoped. Re-run a policy simulation after any refactor of those lists.

### 7. Lifecycle: label, push, close, delete

🔴 **Make the opt-in a label, not a word in the PR title.** Both gate spend, so the choice
looks cosmetic and gets "simplified" to a title match during a rewrite. It is not cosmetic:

- **A title is prose for humans.** Making it config means every edit to it is a
  configuration change with a billing consequence — renaming a PR for clarity silently
  creates or destroys an environment. A label is metadata, which is what metadata is for.
- **A substring match collides with the vocabulary of the thing it gates.** In a repo whose
  commit scopes look like `preview: fix the teardown guard`, every PR *about* the preview
  system provisions one. Observed in the wild; harmless until it isn't.
- **No permission boundary.** Anyone who can open a PR can spend money. Labelling is gated
  on write/triage.
- **No audit trail.** A label records who enabled it and when, in the timeline. A title edit
  is buried in history.
- **`unlabeled` is a free park signal** — turn a slot off without closing the PR. Titles give
  you no such event.

What a title genuinely wins: visible in list view without opening the PR, and no label to
create first. Neither is worth the coupling.

⚠️ **If a rewrite moves the trigger, say so in the PR body and fix the docs in the same
change.** One real sequence: a label gate, then a rewrite that deleted the workflow holding
it and shipped with no gate at all (every PR got an environment), then a day later a title
match added back by someone who did not know a label had ever existed. The skill describing
it stayed wrong for two days and sent its readers to add a label that fired nothing.


| Event | Action | Why |
|---|---|---|
| `pull_request: labeled` | create + deploy | the label is the opt-in |
| `pull_request: synchronize` | redeploy | every push after |
| `pull_request: closed` | **park** — scale to 0 | a close is not "finished" |
| `delete` (branch) | **destroy** + drop the database | a deletion is a decision |

**Park on close, destroy on delete.** A PR closes for reasons that are not finished — a
retitle, a base change, a misclick, a reopen next morning — and a dropped database cannot be
recovered. Scaling to zero removes essentially the whole recurring bill (the container task
*is* the cost; storage, DNS, certificates and CDN are cents at preview traffic) while keeping
the database and hostnames exactly where they were. Make the next deploy set the count back
to 1 explicitly — a rolled service at 0 deploys nothing and reports success, which reads as
broken rather than parked.

**Destroy on an act, not a timer.** Idle time only guesses, and it guesses wrong on the branch
that sat untouched over a holiday and still mattered.

Omit `opened` and `reopened`: a PR is essentially never labelled at the moment it opens, so
they only ever produce a run that skips itself. Trigger types carry no label filter — a
job-level `if:` is the only mechanism, and it still leaves a skipped run on the PR.

### 8. Cap concurrent slots, counted from live infrastructure

Parking bounds *abandoned* slots; nothing bounds live ones, and the label is one click.

Count **running services**, not IaC workspaces — a workspace outlives a half-destroyed slot,
and it is the running task that costs money. Put the check *after* the "does this slot already
exist" early exit, so a redeploy is never blocked by the cap. **Refuse, don't queue**: a
preview nobody can create is a visible problem with an obvious fix; one that silently waits is
not.

### 9. A teardown that cannot lie

🔴 **Do not key existence on one resource being alive.** IaC destroys the compute early, so a
destroy that fails part-way leaves buckets, certificates and DNS records billing while the
*next* teardown looks at the dead service, concludes the slot is gone, skips every step and
reports **success**. The orphans bill forever and nothing says so.

Ask two separate questions:

| | asks | gates |
|---|---|---|
| service alive? | can a one-off task still reach the database? | the database drop only |
| state non-empty? | is anything left to destroy? | **authoritative** — the destroy |

🔴 **Drop the database before destroying the infrastructure.** Afterwards there is no route
into the private subnet and the database is stranded, holding the name a reopened PR wants. On
a failed drop, leave the infrastructure standing — it is the only way back in.

🔴 **Refuse to destroy from the default/shared workspace.** With `manage_shared=false` (or
equivalent) the shared resources get `count = 0`, so a destroy there removes the whole preview
system — including the role running the destroy and the one permanently-allowlisted auth
callback that has no API to recreate. Validate the slot name against the same anchored pattern
the forwarder uses, *and* add a `workspace show` backstop immediately before the destroy.

🔴 **Give teardown a `workflow_dispatch` alongside the event trigger.** On `delete` alone every
test costs a branch: create a slot, delete the branch, watch it fail, fix, and you now need a
new branch *and* a new slot. A workflow whose failure mode is "half-destroyed" and which
cannot be re-run is the wrong shape.

**Enumerate the teardown role's actions from a real destroy** before writing its policy — see
`references/destroy-actions.md`. IAM action names frequently do not match the operation.

## GitHub Actions traps

🔴 **`delete` and `workflow_dispatch` workflows run the file from the DEFAULT BRANCH.** A
teardown does nothing until it is merged, and cannot be tested by deleting the branch it lives
on. Corollary: `workflow_dispatch` is not even offered until the file is on the default
branch — which is exactly why spin-up must be `pull_request`-triggered, not dispatch-triggered.

🔴 **`on: delete:` needs the colon.** A bare scalar followed by a sibling mapping key is
ambiguous YAML: GitHub kept honouring the delete trigger and **silently dropped**
`workflow_dispatch`, so `gh workflow run` answered *"Workflow does not have
'workflow_dispatch' trigger"* while the file plainly contained one.

⚠️ **`$GITHUB_OUTPUT` is a key=value file.** Pretty-printed JSON fails the step with
`Invalid format '    "key": {'`. Pipe through `jq -c`, or use heredoc delimiters.

⚠️ **`github.event.ref` is empty on a dispatch.** A concurrency group keyed on it alone puts
every dispatched run in one group and serialises unrelated slots. Use
`${{ github.event.ref || inputs.slot }}`.

⚠️ **`cancel-in-progress: false` on deploys.** An interrupted task-def roll leaves the service
on an ambiguous revision.

⚠️ **Order tool-setup steps before the steps that use them** — and unconditionally, when a
later `if:` depends on an answer that step computes. A gated setup that gets skipped fails with
`command not found` and skips everything downstream, which reads as "nothing to do".

⚠️ **Path-filter the deploy** (app dirs, packages, lockfile, the workflow itself) so a
docs-only push doesn't rebuild an identical bundle — then tell operators that a docs-only push
will *not* redeploy, and that removing and re-adding the label forces one.

## Verify before claiming it works

Prove the whole lifecycle on one throwaway PR, in order, reading the output of each:

1. unlabelled → **no run** created
2. labelled → resource count applied, and an **HTTP status** on the app *and* the API
3. push → redeployed, the new image tag serving
4. close → task count is `0`, database still present
5. delete the branch → `Destroy complete!` with a count, workspace gone, and **an independent
   sweep for orphans** by name prefix (buckets, certificates, DNS records, log groups)

Then confirm the shared environment is untouched: the shared stack plans **no changes**, and
any argument you added to a shared module (a boundary, `force_destroy`, a desired count)
appears **zero times** in its plan.

## Never

- Never widen an existing admin role's OIDC trust to `pull_request`.
- Never grant `iam:CreateRole` from a PR-triggered role without a boundary condition on it and
  an explicit deny on removing the boundary.
- Never let two roles' credentials coexist in one job.
- Never redirect to a URL taken from OAuth `state`. Construct it from a validated slug.
- Never gate fixture-writing or database-dropping on an environment flag when the resource
  name can be the gate.
- Never destroy from the default/shared workspace.
- Never report a slot as gone on the strength of one dead resource — read the state.
- Never run a preview branch's migrations against a shared database.
- Never leave a stale claim in the PR comment the workflow posts. It is the one surface every
  reviewer reads, so an outdated line there misinforms everyone at once.
