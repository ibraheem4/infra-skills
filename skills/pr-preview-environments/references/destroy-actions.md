# Enumerating a teardown role's IAM actions

Derive this table from `terraform state list` (or the equivalent) on a **real** slot, then
from a **real destroy**. Not from memory, and not by reasoning about the API — that is the
mistake this file exists to stop.

Six of seven gaps in one real build came from assuming the IAM action name matches the
operation. Two of those were recorded as *"none"* in the first version of the table below,
by reasoning rather than running, and only a failed destroy corrected them.

Each failure costs a teardown run that dies part-way, leaving a slot with its database
already dropped and its infrastructure still billing — a state only a human can finish.

## The pattern

A delete is often not a `Delete`:

| Shape | Example | Resource |
|---|---|---|
| a `Put` | `s3:PutBucketPublicAccessBlock` | `aws_s3_bucket_public_access_block` |
| a `Put` | `s3:PutBucketVersioning` | versioning cannot be switched off — it is set to `Suspended` |
| a `Put` | `s3:PutEncryptionConfiguration` | destroy *resets* the configuration |
| a `Put` | `s3:PutBucketOwnershipControls` | `aws_s3_bucket_ownership_controls` |
| a `Remove` | `elasticloadbalancing:RemoveListenerCertificates` | `aws_lb_listener_certificate` |
| a `Revoke` | `ec2:RevokeSecurityGroupIngress` / `Egress` | the rule resources |
| a `Change` | `route53:ChangeResourceRecordSets` | deletion is a change, not a delete |
| an `Update` too | `cloudfront:UpdateDistribution` | must be **disabled** before it can be deleted |
| an `Update` too | `ecs:UpdateService` | scaled to 0 before deletion |
| unscopable | `ecs:DeregisterTaskDefinition` | **no resource-level permissions** — an ARN-scoped statement reads tighter and is DEAD |

## The S3 force-destroy set

A versioned bucket with `force_destroy` needs all four, and the middle two are the ones
people miss:

```
s3:DeleteBucket
s3:ListBucketVersions      ← a DISTINCT action from s3:ListBucket
s3:DeleteObjectVersion     ← not s3:DeleteObject
s3:DeleteBucketPolicy
```

## Other easily-missed pairs

- Reading a KMS-encrypted secret needs `kms:Decrypt` **and** `kms:GenerateDataKey`, not just
  `secretsmanager:GetSecretValue`.
- Terraform workspace state lives at `env:/<workspace>/<key>`. A backend policy scoping only
  the bare key locks out every non-default workspace, and the error names the key, not the
  prefix.
- Actions that genuinely cannot be ARN-scoped (CloudFront, ACM, Route 53 zone reads,
  `ec2:CreateTags`/`DeleteTags`) belong in their own explicitly-named `"*"` statement, so a
  reader can tell "unscopable" from "unscoped by accident".

## Method

1. `terraform state list` on a live slot → the resource inventory.
2. For each, find the delete call the provider makes — provider source or a trace run, not
   the AWS docs' resource page.
3. Grant, then **run a real destroy** on a throwaway slot.
4. When it fails, add the one action named in the error and re-run. Record it here.
5. Re-run a policy simulation after any refactor that merges or splits the action lists.

Never satisfy a failing destroy by widening to `"*"`. That is how a teardown role becomes an
admin role, and it is invisible afterwards.
