#!/usr/bin/env bash
# Emit a Route 53 change batch for a Google Workspace DKIM record.
#
# Why this exists: a DNS TXT *character-string* caps at 255 bytes. A 2048-bit
# DKIM key is ~410, and Route 53 will not split it for you — it rejects the
# value outright. The record has to be handed over as several quoted strings
# inside one TXT value; resolvers concatenate them back with no separator.
#
#   ./dkim.sh <domain> <p-value>          > batch.json
#   aws route53 change-resource-record-sets --profile <profile> \
#       --hosted-zone-id <ZONE> --change-batch file://batch.json
#
# Selector is `google` — Google Workspace's default, and what the
# domains audited here already use. Verify with:
#   dig +short TXT google._domainkey.<domain>
set -euo pipefail

domain="${1:?usage: dkim.sh <domain> <p-value>}"
key="${2:?usage: dkim.sh <domain> <p-value>}"

record="v=DKIM1; k=rsa; p=${key}"

# Split into 255-char chunks, each wrapped in escaped quotes for the JSON value.
value=$(printf '%s' "$record" | fold -w 255 | sed 's/^/\\"/; s/$/\\"/' | paste -sd' ' -)

cat <<JSON
{
  "Comment": "Google Workspace DKIM for ${domain} (selector: google)",
  "Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "google._domainkey.${domain}.",
      "Type": "TXT",
      "TTL": 3600,
      "ResourceRecords": [{ "Value": "${value}" }]
    }
  }]
}
JSON
