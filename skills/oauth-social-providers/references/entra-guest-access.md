# Entra guest access

The tenant may not own the operator's email domain, which makes the operator a B2B guest and
makes the CLI fail in ways that read as permissions rather than identity. Check before blaming
permissions:

- `login.microsoftonline.com/<domain>/v2.0/.well-known/openid-configuration` returning
  `AADSTS90002` means the domain is not an Entra tenant at all.
- `getuserrealm.srf?login=<upn>&json=1` returning `NameSpaceType: Unknown` means the same.
- An ID token with `idp: mail` is an email one-time-passcode B2B guest.

An OTP guest has no home tenant, so plain `az login` fails with *"couldn't find an account
with that username"* — it defaults to the `organizations` authority. Name the tenant, and ask
for a Graph scope rather than the default ARM one:

```
az login --use-device-code --tenant <tenant> --allow-no-subscriptions \
  --scope "https://graph.microsoft.com//.default"
```

A guest with no cloud RBAC cannot get an ARM token, and the browser then shows *"sign-in was
successful but you don't have permission"* — **while the CLI still receives its Graph token.**
That page is cosmetic; check `az ad signed-in-user show` before believing it failed.

⚠️ `az account show` stays green on an expired refresh token. Guard on a real Graph call.

## The same check decides who can test sign-in

Those two lookups answer a second question: whether an address can sign in through Microsoft
at all. `/common` resolves consumer MSAs and Entra tenants, and nothing else — so an address
on a non-Microsoft mail provider returns `NameSpaceType: Unknown` and is rejected with
*"We couldn't find an account with that username"*, no matter how the app is configured.

Being a B2B guest in the tenant does not help: a guest is a foreign identity the tenant has
invited, not an account `/common` can resolve. The operator who registered the app is
therefore often the one person who cannot test it. To exercise the work-account path you need
a member account in a tenant — a licensed user in your own, or a design partner's.

Each completed test sign-in creates a real user in the target environment. Plan for that
before testing against one that holds production users.
