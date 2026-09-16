# Failure modes

Observed, each one having cost something. Dated so a fix upstream can retire an entry.

## `gcloud` inside a `while read` loop eats the loop's stdin — 2026-08-30

```bash
while read -r name; do
  gcloud secrets versions disable "$v" --secret="$name"   # consumes the loop's input
done < list.txt
```

`gcloud` is a Python program that reads stdin, so it swallows the remaining lines of the file feeding the loop. The loop silently skips entries **and** reports failures that did not happen — a first pass claimed fifteen failures, and every version it named disabled fine when retried by hand.

**Fix:** `</dev/null` on every `gcloud` call inside a loop. Then verify by re-enumerating actual state rather than trusting the counters the loop incremented.

## Data Access audit logs are off by default — 2026-08-30

`AccessSecretVersion`, and every other read, is a DATA_READ operation and is **not logged unless someone turned it on**. Admin activity — create, delete, disable — is always logged, so the log looks populated while containing no read history whatsoever.

**Consequence:** "which of these are we using" cannot be answered from logs on a project where nobody enabled it. Use repository grep plus live service bindings. Enable it scoped to the service if a second sweep is expected.

## Billing linked to a closed account is a no-op — 2026-08-30

```
billingAccountName: billingAccounts/011D95-...
billingEnabled: false
```

A project can name a billing account and still have billing disabled, because the *account* is closed (`OPEN: False` in `gcloud billing accounts list`). Linking a closed account changes nothing and reports success. The API error says "requires billing to be enabled" and suggests waiting for propagation, which sends you off looking for a delay that is not there.

**Fix:** check `gcloud billing accounts list` for `OPEN`, not just whether a link exists.

## A resource with zero versions looks like a disabled one — 2026-08-30

Two secrets had no versions at all — never populated, or all destroyed. A filter for "no enabled versions" matches them exactly as it matches something you just disabled, so a sweep will happily report them as its own work and a delete-what-I-disabled step will take them.

**Fix:** distinguish *zero versions* from *versions, all disabled*, and exclude anything you did not disable yourself.

## Config in a frozen repository still names live resources — 2026-08-30

A frozen or legacy monorepo can hold complete, correct deployment configs — Cloud Build YAML, Cloud Run service definitions — that bind resources by name. Grep cannot tell that apart from a live binding.

**Fix:** the deployed service list is the arbiter. If the service is not in `gcloud run services list`, its config is not evidence of use — but note it in the record, because redeploying it later will need those resources recreated.
