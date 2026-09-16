---
name: aws-infra
description: Use when working on AWS or infrastructure — Terraform, ECS, Route 53 or DNS, ACM, IAM and GitHub OIDC deploy roles, SSO credentials, or migrating an app onto AWS from a PaaS. Carries the region and AZ convention, the DNS delegation pattern that avoids taking company email down, the deploy-role naming a research doc gets backwards, and where a reference implementation stops being a precedent.
---

# AWS & infrastructure

## Overview

Every rule here was paid for. Two of them — the apex nameservers and the derived AZ — guard
changes that destroy things quietly, where the damage is done before anything reports an
error. The rest are places a document confidently names the wrong thing.

## Profile

Every workspace value here comes from a profile, never from this skill. Resolve one first:
`~/<workspace>/.claude/workspace.config.md` — the workspace the caller named, or the single
match of `~/*/.claude/workspace.config.md`. Several matches: ask which. None: say which keys
are needed and stop.

| Key | Used for |
|---|---|
| `{{cloud_region}}` | default region |
| `{{cloud_az}}` | the AZ to pin explicitly |
| `{{sso_session}}` | the session name that actually refreshes credentials |
| `{{accounts}}` | profile → account id map |
| `{{deploy_role_pattern}}` | the OIDC deploy role convention, and the resolved name per env |
| `{{apex_domain}}` | the domain whose nameservers must never be repointed |
| `{{delegated_zones}}` | per-environment zones already delegated, and what each still awaits |
| `{{reference_infra_repo}}` | the in-house Terraform being copied |
| `{{infra_owner}}` | who holds the apex zone and the registrar |

## When to Use

- Writing or reviewing Terraform for any account in `{{accounts}}`
- Anything touching Route 53, ACM, or a hostname under `{{apex_domain}}`
- Wiring a GitHub Actions deploy, or debugging `AssumeRoleWithWebIdentity`
- Scoping an app's move off a PaaS onto AWS

## 1. Credentials

🔴 **Refresh with `aws sso login --sso-session {{sso_session}}`.**

Check what a helper script tells you to run before running it. One `dev-secrets.sh` prints a
session name that **does not exist in `~/.aws/config`** — the profile carries a different
`sso_session`. The script's own remediation therefore fails, and it fails at the worst
moment, because a secret fetch breaks exactly when the token has expired, which is the first
thing every developer hits.

Fix the invocation, not the profile. Repointing the profile to match a wrong message breaks
everyone else.

## 2. Region and AZ

🔴 **Pin `{{cloud_az}}` explicitly.** A standing convention, not a per-stack choice.

**Never derive an AZ from another resource.** An EBS data volume that took
`availability_zone = aws_instance.x.availability_zone` turned that attribute into "known
after apply" on any instance replacement, which forced the **volume** to be replaced too —
destroying the data on every upgrade, precisely what a separate volume exists to prevent.
`terraform plan` caught it; nothing else would have.

So: declare an `availability_zone` variable defaulting to `{{cloud_az}}` and reference that.
Where a subnet is also involved, add a `precondition` asserting the subnet's AZ matches, so a
mismatch fails at plan time with a readable message instead of at apply with an attach error.
Pair it with `prevent_destroy = true` on anything holding state.

The general form: **never let a replaceable attribute feed a resource that holds state.**

## 3. DNS — the apex is live production

Check the registrar before assuming who controls the domain. `{{apex_domain}}` is registered
directly with a registrar, not through the PaaS that serves its traffic — the PaaS only
receives requests, via `CNAME` records published from a hosted zone. Verify with `whois`
rather than inferring from where traffic lands.

Where the live zone is not in an account you hold, it belongs to `{{infra_owner}}`. Establish
that by elimination — list zones in every account you do hold — and then leave it alone.

🔴 **Never repoint the registrar's nameservers at a newly created zone.** A second zone for
an apex was created holding only its own `NS` and `SOA`. Cutting NS to it would have taken
down the apex site, `www`, the docs host, a customer's live environment, the Google
site-verification `TXT`, `_dmarc`, and `MX` — **all company email**. It was deleted the same
day. Owning an apex means replicating every record first; that is its own project, never a
migration step.

**The pattern that works:** one `NS` delegation per environment into a zone you own in that
account, so Terraform resolves the zone in-account and ACM auto-validates. `{{delegated_zones}}`
records which are done and what each still awaits.

⚠️ A hostname that already points at the PaaS cannot be delegated early — delegating that
exact name **is** the production cutover. Delegate the environment subdomains first.

Before any DNS change, check what the name already resolves to. Treat `MX` and any docs host
as production, because they are.

## 4. A reference implementation stops where its stack stops

`{{reference_infra_repo}}` is the in-house Terraform being copied. Confirm `terraform plan` is
clean against its live environments — if it is, the modules do apply as written.

⚠️ **Then check that it deploys the same *kind* of app.** One such reference ran its
web tier as a static SPA on S3 + CloudFront, not a container: no Dockerfile for it, container
repos only for the API services, and zero framework dependencies for server rendering. The
app being migrated was a server-rendered framework needing a running container.

So "we already did this migration" is true for infrastructure and **false for the web tier**.
Anything specific to the new runtime is unpaid work with no precedent to copy. Treat these
`ecs-service` gaps as new module development, not configuration:

| Gap | Typical live value |
|---|---|
| `healthCheckGracePeriodSeconds` | 0 |
| container `healthCheck` | null |
| `stopTimeout` | absent |
| pre-deploy / one-off task hook for DB migrations | none |
| `cpu_architecture` | hardcoded to one architecture |

Add the grace period **first** and prove a task goes healthy before wiring the load balancer.
A deployment circuit breaker with `rollback: true` will revert a slow-starting container and
the failure reads as a bad image.

## 5. Deploy roles

The OIDC deploy role convention is `{{deploy_role_pattern}}`. **Verify it against live IAM**
before writing any deploy workflow:

```sh
aws iam list-roles --profile <profile> | grep gha
```

⚠️ A research doc "corrected" a handoff's role name by transposing the scope and the verb.
The handoff was right; the correction was the error. Copying the wrong name into a workflow
gives an `AssumeRoleWithWebIdentity` failure that reads like a trust-policy problem, so the
debugging goes somewhere else entirely and costs hours.

A confident correction in a document is not evidence — see the `agent-skills:verify-before-cite` skill.

## 6. Migration plans mis-size work they never checked

🔴 A runbook's repo copy may be a phantom. One existed only as an **untracked** file inside a
worktree — on no other machine, not on the remote — while the wiki copy said "also in the
repo at…". Editing that copy reached nobody. Confirm with `git log --all -S` before trusting
or editing a repo-resident runbook, and treat the wiki copy as the one that counts.

Two corrections of this kind resized real work, and both generalize:

- **Verify each service's actual language and runtime.** A plan that assumed one framework
  for a service written in another under-costed it by 2–3× — a "+4–6 h fifth service" was
  really 10–14 h.
- **Check which services must stay publicly reachable.** A service owning a browser-facing
  auth callback cannot be a private mesh-only service; it needs a public listener rule. A
  plan that makes it private looks cheaper and does not work.

## Never

- Never repoint `{{apex_domain}}`'s registrar nameservers. Delegate a subdomain instead.
- Never derive an availability zone from another resource. Declare `{{cloud_az}}`.
- Never take a role name, ARN, zone id or account id from a document without a
  `describe` / `list` / `get` first — see the `agent-skills:verify-before-cite` skill.
- Never name an org outside this profile in a doc, ticket or runbook. Filter local config
  sweeps (`aws configure list-profiles`) before anything reaches a written artifact.
- Never `terraform apply` on a read-only task, and never on your own initiative.

## Common Rationalizations

| Excuse | Why It's Wrong |
|---|---|
| "I'll just point the nameservers at the new zone" | That is the apex. Mail and the docs host go down with it |
| "The AZ will resolve from the instance" | Until the instance is replaced, and it takes the volume with it |
| "The research doc corrected the role name" | Check live IAM. The correction is as likely to be the error |
| "We already did this migration" | True for the infrastructure, false for a different runtime |
| "The runbook is in the repo too" | Confirm it was ever committed. One existed only inside a worktree |

## Verification

- [ ] Every resource name came from a `describe`/`list`/`get`, not a document
- [ ] The AZ is declared, not derived, and state-holding resources carry `prevent_destroy`
- [ ] Any DNS change was checked against what the name currently resolves to
- [ ] A new task was proven healthy before the load balancer was wired to it
- [ ] Nothing was applied on a read-only task
