# Mail-auth failure modes observed in production domains

Each of these was found on a live domain. They are recorded because every one of
them presents as working in the console it was configured from.

## 1 · DKIM in the apex TXT — the failure that looks like success

**Observed 2026-08-29 on `example.org` and `example.net`.** Both domains had a
correct, current, 2048-bit Google Workspace DKIM key published — in the apex TXT
record, alongside SPF and the site-verification token.

DKIM is only ever read from `<selector>._domainkey.<domain>`. A key at the apex
is never consulted by any verifier. Both domains had been signing mail that
nobody could verify, for as long as the paste had been there.

```
dig +short TXT example.net                        # key is here     ← wrong
dig +short TXT google._domainkey.example.net      # empty           ← what matters
```

Why it survives: Google Admin shows the key it *wants* published, the registrar
shows a TXT record containing that key, and a human comparing the two sees a
match. Nothing in either console names the record.

**Detection:** query the selector directly. The audit script does this and warns
separately when a `v=DKIM1` string appears in the apex.

**Repair:** publish at the selector. Removing the apex copy is optional — it is
inert — and modifies the record holding SPF, so it should be a deliberate,
separate change rather than a tidy-up.

## 2 · The 255-byte character-string cap

A DNS TXT *character-string* caps at 255 bytes. A 2048-bit RSA DKIM record is
about 410:

```
v=DKIM1; k=rsa; p=<392 chars>   =  410 bytes
```

Route 53 rejects an over-long string rather than splitting it. The record has to
be handed over as multiple quoted strings inside one TXT value:

```json
"Value": "\"v=DKIM1; k=rsa; p=MIIBIjAN…WfLC0\" \"4rmBBVX…IDAQAB\""
```

Resolvers concatenate the strings with **no separator**, so the split may fall
anywhere — including mid-token — without harm. `scripts/dkim-batch.sh` does this
at 255 and the observed result is two chunks of 255 + 155.

Always verify by reassembling what the resolver returns and comparing it to the
key you were given, rather than eyeballing the prefix. Two different keys share
the first ~50 characters, because that span is ASN.1 header, not key material:

```
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA…   ← identical on every 2048-bit key
```

## 3 · Delegation broken by zone recreation

**Observed on `mail.example.com`,** now repaired. Deleting and recreating a Route 53
hosted zone assigns a **fresh** NS set; Route 53 never reuses the previous one.
The registrar keeps advertising the old four, which answer `REFUSED`, and the
domain goes dark while both consoles look perfect.

**Detection** — compare the parent TLD's delegation against the zone's own set:

```
dig +noall +authority NS <domain> @a.gtld-servers.net | awk '{print $5}' | sort
aws route53 get-hosted-zone --id <ZONE> --query DelegationSet.NameServers
```

Run it after any zone recreation, and before writing into a zone you did not
create in this session. Editing a zone the internet does not query produces a
change id, an `INSYNC` status, and no effect whatsoever.

## 4 · Additive versus rotation

The two cases carry very different risk and must not be handled identically.

| | Selector empty | Selector occupied, different key |
|---|---|---|
| Risk | none — cannot be worse than absent | **working → broken** if the provider still signs with the old key |
| Before writing | nothing | capture the record, build a rollback batch |
| Failure | still broken | every signed message fails DKIM |

Blast radius is set by the DMARC policy, so read it first: under `p=none` a bad
rotation produces report lines only; under `p=quarantine` or `p=reject` it
produces lost mail.

Publishing DNS does not complete a rotation. Google Workspace continues signing
with the old key until **Apps → Google Workspace → Gmail → Authenticate email →
Start authentication** is run for that domain.

## 5 · SPF alignment and a custom MAIL FROM

`aspf=s` (strict) cannot align when the MAIL FROM subdomain differs from the
header domain — `mail.example.com` versus `example.com` is an *organisational* match,
which is what relaxed means. Setting strict there throws away the SPF pass
entirely and leaves DMARC resting on DKIM alone.

## 6 · The permission classifier

Adding a new record is permitted; modifying an existing production record is
blocked. Do not retry a blocked call — hand it to the operator as a `!` command.
This is why a rotation and an apex cleanup are operator-run while an additive
publish is not.

## Known-good reference

Confirm shape against a domain already correct rather than from memory:

```
dig +short TXT google._domainkey.example.com     # 416 bytes, selector `google`
dig +short TXT _dmarc.example.com                # p=quarantine, adkim=s, aspf=r
```
