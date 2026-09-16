---
name: oauth-social-providers
description: Use when wiring Google or Microsoft social sign-in for a WorkOS AuthKit environment — registering the upstream Entra app or Google OAuth client, capturing a client secret that is shown exactly once, or saving credentials onto a credential record. Carries the ordering that cannot be replayed, the three gates that reject sign-ins for reasons unrelated to your credentials, and how to prove a provider is wired without signing in.
---

# WorkOS social OAuth providers

## Overview

Three of these rules cost a credential each. Both providers show a client secret once and
never again, so the expensive mistakes are ordering mistakes. The rest of the skill is the
reverse problem: sign-ins that fail, or seem to work, for reasons unrelated to credentials.

## Profile

Every workspace value comes from a profile, never this skill. Resolve one first:
`~/<workspace>/.claude/workspace.config.md` — the workspace the caller named, or the single
match of `~/*/.claude/workspace.config.md`. Several matches: ask. None: name the keys, stop.

| Key | Used for |
|---|---|
| `{{accounts}}` | which account owns the secret |
| `{{sso_session}}` | the session name that actually refreshes credentials |
| `{{cloud_region}}` | region for the secret and its CMK |
| `{{exclude_orgs}}` | tenants and orgs that must never receive these resources |

Secret naming, per-product project naming and the app-per-product rule are the workspace's
conventions, not this skill's. Read them before creating anything.

## When to Use

- Adding Google or Microsoft sign-in to an AuthKit environment
- Registering an Entra app registration or Google OAuth client for it
- Capturing or rotating a provider client secret
- Diagnosing a social sign-in that fails, or that works but on the wrong credentials

## 1. Ordering — the callback slug is not yours to choose

The callback URI carries a random per-provider slug, so it can only be read, never built:

1. Open the provider's dialog in the dashboard and read the callback URI off it. There is no
   API to create a record, and never reconstruct the URI.
2. Reload the page and re-read it. If it is unchanged while the provider still shows as
   disabled, it is allocated and safe to register — see [references/secret-capture.md](references/secret-capture.md).
3. Register that URI upstream, in Entra or Google.
4. Save the client ID and secret onto the record.

🔴 **Create the destination secret before the upstream app.** An app whose secret has nowhere
to go is an orphan the moment the dialog closes.

## 2. The secret is shown once

Both providers display a client secret exactly once, at creation. Google removed viewing
entirely; Entra never had it. There is no recovery — only rotation.

So the capture is a single uninterrupted sequence, and everything about it is covered in
[references/secret-capture.md](references/secret-capture.md): the safe order, why reading the
page to find the control leaks the value, and why a page reload destroys it.

Use `scripts/oauth-secrets.sh` as the destination. It never echoes a value, never puts one in
argv, and `put-stdin` lets a generator pipe straight in:

```
az ad app credential reset --id "$app" --years 1 --append --query password -o tsv \
  | oauth-secrets.sh put-stdin <secret-id> MICROSOFT_OAUTH_CLIENT_SECRET
```

🔴 **One secret per client.** To add an environment, rotate the single secret and update every
record using it — never stack a second. Both providers permit multiples and both make the
older value unrecoverable, so extras become permanent orphans. Google caps a client at two,
and freeing a slot is disable-then-delete, irreversible.

## 3. Microsoft has two hard requirements

**The identity provider must opt your team in.** Microsoft OAuth is consumers-only by
default — a mitigation for the nOAuth vulnerability — so M365 work accounts are rejected
outright. WorkOS enables work accounts on request. Check whether it is already on before
asking again: it may be team-wide rather than per-environment, in which case a new project
inherits it.

**The Entra app must set `signInAudience: AzureADandPersonalMicrosoftAccount`.** That is the
provider's requirement and the precondition for the opt-in. Graph refuses that audience
unless the app also carries `api.requestedAccessTokenVersion: 2`, and `az ad app create` has
no flag for it. So create under `AzureADMultipleOrgs`, then PATCH both fields in a **single**
Graph call — setting the audience alone returns *"Application must accept Access Token
Version 2"*. Verify the audience actually took; a silent fallback looks like success and
rejects every work account at sign-in.

Personal Microsoft accounts therefore cannot be excluded at the Entra level while keeping
work-account sign-in. Exclude them downstream, by mapping the verified email domain to an
organization and failing closed when there is no match.

Resolve Graph delegated-scope IDs at runtime rather than hardcoding GUIDs — two separate
hardcoded guesses of the `email` scope were wrong before it was read live:

```
az ad sp show --id 00000003-0000-0000-c000-000000000000 \
  --query "oauth2PermissionScopes[?value=='email'].id | [0]" -o tsv
```

### Guest access

An operator whose email domain the tenant does not own is a B2B guest, and `az login` then
fails in ways that read as a permissions problem. See
[references/entra-guest-access.md](references/entra-guest-access.md).

## 4. Google is console-only, permanently

There is no API for creating OAuth clients. The only CLI surface was
`gcloud alpha iap oauth-brands` / `oauth-clients`, and the IAP OAuth Admin APIs were shut
down in March 2026. Every client is created by hand.

Consent screen: app name, audience **External**, support and contact email. Then a **Web
application** client with the callback as its one redirect URI — verify it character-exactly
first, since an accessibility tree does not expose input values.

## 5. Three gates that are not your credentials

**`Invalid` on a credential record does not mean broken.** The provider shows as *Enabled with
a demo-credentials badge*: the environment is signing users in on the identity provider's
shared demo client because "your app's credentials" was selected but never saved. Sign-in
works. It still matters — the consent screen is theirs — but it is not an outage.

**A fresh Google consent screen is gated by publishing status.** It starts in **Testing**,
where only listed test users can sign in, and a new project has **zero**. Every Google
sign-in is rejected for a reason unrelated to the credentials. Either add test users —
immediate, no review, 100 over the app's lifetime — or publish, which needs privacy and terms
links and possibly verification. Microsoft has no equivalent gate. Re-read the test-user list
after a reload — that save can no-op silently ([references/secret-capture.md](references/secret-capture.md)).

⚠️ The consent screen is branded by the **authorized domain**, which is auto-added from the
callback host — so it shows the identity provider's domain, not your app name, however the
app name is set. Fixing that needs a custom auth domain on the provider, which changes every
callback URI and means re-registering them upstream. Decide before customers see it.

**A Microsoft sign-in can fail because the address is not a Microsoft identity.** An email on
a non-Microsoft mail provider resolves to no Entra tenant and no consumer MSA, so `/common`
returns *"We couldn't find an account with that username"* — indistinguishable from a broken
registration. A B2B guest does not resolve there either, so whoever registered the app is
often the one person who cannot test it. Check the address first:
[references/entra-guest-access.md](references/entra-guest-access.md).

## 6. Domains are free; environments are not

The URI you register upstream belongs to the **identity broker**, not your app:
`https://auth.workos.com/sso/oauth/<provider>/<slug>/callback`. Your hostname appears nowhere
in Entra or Google, so a rename, a new apex, or a staging/production split changes nothing
upstream — re-registering "to be safe" spends a secret for no gain. Such a move touches only
the broker's app-callback allowlist and your env vars.

Adding an **environment** is the opposite: its own record, own slug, own registration — and
its own client, since a shared one puts a staging secret in production (§2 forbids stacking).

## Verification

Prove a provider is wired without credentials and without a browser:

```
curl -sS -o /dev/null -D - \
 "https://api.workos.com/user_management/authorize?client_id=<env client_id>&redirect_uri=<registered uri>&response_type=code&provider=GoogleOAuth" \
 | awk 'tolower($1)=="location:"{print $2}'
```

Read the `Location`:

- Google must be `accounts.google.com` carrying **your** client ID, not the provider's demo one.
- Microsoft must be `login.microsoftonline.com/common/oauth2/v2.0/authorize`. `login.live.com`
  with `tenant=consumers` means the work-account opt-in is not active.

The `redirect_uri` must already be registered on the environment. Swap `provider` for
`MicrosoftOAuth`. For a full sign-in, open the same URL: success is landing back on the
callback with `?code=`, and an app error *after* that redirect still means auth passed.

After saving, confirm over the API that the record's state moved to valid and that its
redacted secret matches the tail of what you banked.

## Common Rationalizations

| Claim | Why it is wrong |
|---|---|
| "The record says `Invalid`, sign-in must be broken" | It is on demo credentials and working. §5. |
| "I'll add a second secret so I don't disturb the old one" | Both become unrecoverable; one becomes an orphan. §2. |
| "Google sign-in fails, the credentials must be wrong" | Check publishing status and test users first. §5. |
| "The browser said no permission, the login failed" | Check the CLI's own token; the ARM page is cosmetic. §3. |
| "I'll set the audience, then fix the token version" | Graph rejects the audience alone. One PATCH. §3. |
| "The app name is set, so the consent screen shows it" | It shows the authorized domain. §5. |
| "The app domain changed, so the OAuth config must change" | The callback is the broker's host. §6. |
| "Microsoft rejected my address, so the app is misconfigured" | Check it is a Microsoft identity at all. §5. |

## Never

- Never reconstruct a callback URI; read it from the API.
- Never create an app or client without capturing its secret at creation.
- Never stack a second secret on a client to add an environment.
- Never leave a provider on "your app's credentials" without saving them — it silently keeps
  running on the identity provider's demo client.
- Never let a secret reach a transcript. If one does, treat it as burned, rotate it, and say so.
- Never create resources in a tenant or org from `{{exclude_orgs}}`. Assert the active account
  and target first — a stale CLI default is a real hazard.
