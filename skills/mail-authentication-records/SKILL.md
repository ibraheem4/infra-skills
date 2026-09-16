---
name: mail-authentication-records
description: Publish, rotate, and audit SPF, DKIM, and DMARC records for a  domain in Route 53, including delegation verification, 255-byte TXT chunking, additive-versus-rotation handling, rollback capture, and two-resolver verification. Use when a Google Workspace or SES DKIM key needs publishing, a domain fails DKIM or DMARC alignment, mail authentication looks configured but is not working, or a domain's email posture needs checking.
---

# Mail authentication records

Treat a mail-auth record as a live production control. A DKIM record that exists but sits at the wrong name is indistinguishable from a working one in every console, and two  domains ran that way until somebody queried the selector directly.

Run `scripts/audit-mail-auth.sh <domain>` before and after every change. Read `references/failure-modes.md` when anything disagrees.

## Workflow

1. **Audit first.** Run the audit script. It reports delegation health, SPF, DKIM at the selector, DMARC, and whether a DKIM string is misplaced in the apex TXT. Never write a record before reading this.
2. **Verify delegation before trusting anything.** Compare the parent TLD's NS set against the hosted zone's `DelegationSet`. If they disagree, the zone you are about to edit is not the zone the internet queries — stop and repair delegation first. A recreated hosted zone gets a fresh NS set and Route 53 never reuses the old one.
3. **Classify the change.** Query `<selector>._domainkey.<domain>`:
   - **empty → additive.** Publishing can only improve things. Proceed.
   - **occupied and different → rotation.** You are replacing a key that may be signing mail right now. Capture the current record and build a rollback batch before writing.
   - **occupied and identical → no-op.** Say so and stop.
4. **Build the change batch with the script**, never by hand. A 2048-bit key is ~410 bytes and a DNS TXT character-string caps at 255. Route 53 rejects an over-long string rather than splitting it. The record must be several quoted strings inside one TXT value; resolvers rejoin them with no separator.
5. **Confirm before writing when the change is a rotation or touches a record holding other data.** An apex TXT usually carries SPF and verification tokens alongside anything else pasted there; an UPSERT replaces the whole set.
6. **Apply, then wait for `INSYNC`** with `aws route53 wait resource-record-sets-changed`.
7. **Verify on two resolvers** — the zone's own authoritative nameserver and a public one. Reassemble the chunks and compare byte-for-byte against the key you were given. A record that resolves is not the same as a record that resolves correctly.
8. **Complete the provider side.** Publishing DNS does not turn DKIM on. Google Workspace still needs Apps → Google Workspace → Gmail → Authenticate email → Start authentication. Until that happens a rotation leaves outbound mail signed with a key that is no longer published.
9. **Record the change** — domain, zone id, change id, whether additive or rotation, and where the rollback batch lives.

## Safety rules

- Never publish a DKIM key the requester has not confirmed is current. A wrong key fails every signed message; an absent one merely fails to help.
- Never delete and recreate a hosted zone to "clean it up". Delegation breaks silently and the console still looks correct.
- Treat a rotation as destructive. Capture the previous record and write a runnable rollback batch first.
- Do not remove a stray apex DKIM string as an unrequested tidy-up. It is inert, and removing it modifies the record holding SPF.
- Check the DMARC policy before estimating blast radius. Under `p=none` a broken rotation produces report lines; under `p=quarantine` or `p=reject` it produces lost mail.
- Never paste a DKIM **private** key anywhere. Only the public `p=` value belongs in DNS.

## House conventions

Confirm against a known-good domain (`example.com`, `example.com`) rather than assuming:

- Selector `google` for Google Workspace DKIM.
- SPF `v=spf1 include:_spf.google.com include:amazonses.com ~all` where the domain sends via SES; without the SES include where it does not.
- DMARC reporting to `dmarc-reports@example.com`. Policy varies by domain and is deliberate — do not normalise it.
- `aspf=s` cannot align with a custom MAIL FROM subdomain; that pairing needs relaxed.

## Output

Report per domain: audit before, change classification, zone id, change id, verification result on both resolvers, rollback location if a rotation, provider-side action still outstanding, and anything found but deliberately not changed.

## Resources

- `scripts/audit-mail-auth.sh <domain>` — full posture and delegation audit. Read-only.
- `scripts/dkim-batch.sh <domain> <p-value>` — emits a chunked Route 53 change batch on stdout.
- `references/failure-modes.md` — the failures actually observed on  domains, and how each was found.
