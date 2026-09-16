---
name: gcp-resource-sweep
description: Retire unused Google Cloud resources — secrets, service accounts, Cloud Run services, networking — through a disable-then-delete lifecycle backed by usage evidence rather than by names. Use when cleaning up a GCP project, when asked to delete resources that "look unused", when a cost line needs reducing, or when deciding whether a resource is safe to remove.
---

# GCP resource sweep

**A resource's name tells you nothing about whether it is used.** Two  secrets named for a service that is not deployed were safe to delete; two named for analytics were the only bindings on the only running service. Nothing in the naming distinguished them.

**Google does not log reads by default.** Data Access audit logs are off unless someone enabled them, so `AccessSecretVersion` and its equivalents are never recorded. Admin writes *are* — which is why `DeleteSecret` events exist in a project with no read history at all, and why the log looks populated while answering none of the question.

Run `scripts/usage-evidence.sh` before proposing any deletion. Read `references/failure-modes.md` when a command disagrees with what a console shows.

## Workflow

1. **Snapshot first.** Enumerate the resources and write the list down before touching anything. After a delete the names are the only record that they existed.
2. **Check the registry.** `{{cloud_asset_registry}}.yaml` carries a lifecycle state per asset. **A `retained` or `active` state overrides an instruction to delete** — surface the conflict and get it resolved rather than executing over it.
3. **Gather usage evidence**, because there is no log to read:
   - **Grep every locally checked-out repository** for each resource's canonical name *and* its `SCREAMING_SNAKE` environment form. The distinction decides the answer: a canonical-name hit is a **binding**, a SCREAMING_SNAKE hit is an env var that could come from anywhere.
   - **Read the bindings off what is actually deployed** — `gcloud run services describe` and its equivalents. This is the strongest evidence available and it outranks every grep.
   - **A config file is not a deployment.** A repository can hold a complete Cloud Run YAML binding six secrets for a service that was never deployed or has been torn down. Check the service list, not the config.
4. **Classify** each resource: bound by a live service · referenced by name in a deployable config · env-var reference only · no reference anywhere. Only the last two are candidates.
5. **Disable. Never delete first.** Disabling is reversible, and for anything billed per active unit it captures the entire cost saving immediately — which is usually the whole reason the sweep was requested. Deleting adds no saving and removes the undo.
6. **Verify by ground truth, not by your own tally.** Re-enumerate and count what is actually disabled. A loop that reports what it thinks it did will report it confidently after doing something else — see the stdin trap in the failure modes.
7. **Wait a deploy cycle** — 30 days is the default. Something that reads a resource monthly has to get its chance to fail loudly while the undo is still one command.
8. **Delete, then verify the survivors.** Confirm that everything intended to survive is still enabled, not merely still present.
9. **Record it** in `cloud-assets.yaml` and `log.md`: what was retired, what was retained and why, the evidence used, and the caveats. Names only — never a value.

## Safety rules

- **Never delete before disabling**, whatever the instruction says. Offer the reversible path; it reaches the same end state and costs nothing.
- **Never delete on a name-based guess** when a live-binding check is available and has not been run.
- **Never write a secret value anywhere** — not into the registry, not into a log, not into a commit message, not into a summary. The names are the record.
- **Surface conflicts with the registry before acting**, not after. The person giving the instruction usually does not have the registry in their head.
- **Only repositories checked out locally can be grepped.** Say so in the record; it is the main limit on the evidence.
- Enabling Data Access audit logs for the service being swept, scoped to that service, makes the *next* sweep evidence-based instead of archaeological. It is one command and nobody has run it.

## Output

A record in `registries/cloud-assets.yaml` naming what was retired and what was retained, the evidence behind each, and the caveats — plus a `log.md` entry carrying the traps hit along the way.
