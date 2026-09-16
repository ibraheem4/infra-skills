# Infra Skills

Infrastructure and machine operations for AI coding agents. Split out of
[agent-skills](https://github.com/ibraheem4/agent-skills), which keeps the engineering practice —
these are the ones that touch real infrastructure or a real workstation, where a mistake costs
something outside the repository.

## Cloud and identity

| Skill | Use when |
|-------|----------|
| `aws-infra` | Terraform, ECS, Route 53, ACM, IAM and OIDC deploy roles. Pin the AZ; delegate subdomains rather than repointing an apex |
| `gcp-resource-sweep` | Deleting cloud resources — a resource's name tells you nothing about whether it is used |
| `mail-authentication-records` | SPF, DKIM and DMARC as live production controls; a wrong record drops real mail silently |
| `google-workspace-sso-cutover` | Moving a tenant onto SSO without locking everyone out, including yourself |
| `oauth-social-providers` | Google or Microsoft sign-in for AuthKit — the secret shown exactly once, and three gates that reject sign-ins for unrelated reasons |
| `pr-preview-environments` | Per-PR ephemeral environments: the OIDC trust split, the isolated database, and teardown that reports success while orphaning billable resources |

## Workstation

| Skill | Use when |
|-------|----------|
| `local-bringup` | Cold clone to an app you have *seen* working — toolchain pins, port and database collisions |
| `disk-reclaim` | Reclaiming space: caches before working trees, and `dist/` is not automatically untracked |
| `find-hidden-services` | A process that respawns means you found one spawner, not all of them |
| `triage-failing-fleet` | Collapse logs to distinct lines, then walk the dependency chain to the one upstream cause |
| `safe-repo-removal` | Prove every commit is recoverable before deleting a repository |

Five references point at `agent-skills` skills and are written plugin-qualified, so they resolve
when both are installed and read as an external pointer when they are not.

## Install

```
/plugin marketplace add ibraheem4/claude-marketplace
/plugin install infra-skills@ibraheem4
```

## License

MIT. See [LICENSE](LICENSE).
