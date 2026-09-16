#!/usr/bin/env bash
# Read-only mail-authentication audit for one domain.
#
#   ./audit-mail-auth.sh <domain> [aws-profile]
#
# Reports delegation health, SPF, DKIM at the selector, DMARC, and the two
# failure modes that hid broken domains in plain sight:
#   · a DKIM string sitting in the apex TXT, where nothing reads it
#   · a hosted zone whose NS set no longer matches the parent's delegation
#
# Exits non-zero if either is detected, so it can gate a change.
set -uo pipefail

domain="${1:?usage: audit-mail-auth.sh <domain> [aws-profile]}"
profile="${2:?set the cloud profile}"
selector="${DKIM_SELECTOR:-google}"
status=0

hr() { printf '\n%s\n' "── $* ──────────────────────────────────────────" ; }

hr "$domain"

# ---- delegation ------------------------------------------------------------
# The zone you can edit is only the zone that matters if the parent agrees.
#
# Ask the domain's OWN parent, resolved per-TLD. Hardcoding a gtld-servers host
# works for .com/.net and silently returns the root servers for everything else
# — which reads as a delegation break on every .ai domain we own.
tld="${domain##*.}"
tld_ns=$(dig +short NS "${tld}." | head -1)
parent=""
if [ -n "$tld_ns" ]; then
  parent=$(dig +noall +authority NS "$domain" @"$tld_ns" 2>/dev/null | awk '$4=="NS"{print $5}' | sort)
fi
# Fall back to the resolved answer only if the parent could not be reached; note
# that this compares the zone against itself and cannot detect a stale registrar.
parent_source="parent (${tld} servers)"
if [ -z "$parent" ]; then
  parent=$(dig +short NS "$domain" | sort)
  parent_source="resolver (could not reach ${tld} servers — weaker check)"
fi

zone_id=$(aws route53 list-hosted-zones --profile "$profile" \
  --query "HostedZones[?Name=='${domain}.'].Id" --output text 2>/dev/null)

if [ -n "$zone_id" ] && [ "$zone_id" != "None" ]; then
  zone_ns=$(aws route53 get-hosted-zone --profile "$profile" --id "$zone_id" \
    --query "DelegationSet.NameServers" --output text 2>/dev/null \
    | tr '\t' '\n' | sed 's/$/./' | sort)
  if [ "$parent" = "$zone_ns" ]; then
    echo "delegation : OK — parent and hosted zone agree"
    echo "             checked against $parent_source"
  else
    echo "delegation : BROKEN — parent and hosted zone disagree"
    echo "  checked against   : $parent_source"
    echo "  parent advertises : $(echo "$parent" | tr '\n' ' ')"
    echo "  hosted zone has   : $(echo "$zone_ns" | tr '\n' ' ')"
    echo "  → the zone you can edit is NOT the zone being queried. Repair before writing."
    status=1
  fi
  echo "zone       : $zone_id"
else
  echo "delegation : no Route 53 hosted zone found under profile '$profile'"
  echo "zone       : —"
fi

# ---- SPF -------------------------------------------------------------------
# Read from the zone's OWN nameserver. A public anycast resolver such as 8.8.8.8
# is many independent caches behind one address: two queries seconds apart can
# hit different nodes and return the pre- and post-change record. It is a
# propagation signal, never the source of truth.
hr "records"
auth_ns=$(echo "$parent" | head -1)
[ -z "$auth_ns" ] && auth_ns=$(dig +short NS "$domain" | head -1)
AUTH=(dig +short "@${auth_ns}")

apex=$("${AUTH[@]}" TXT "$domain" | tr -d '"')
spf=$(echo "$apex" | grep -o 'v=spf1.*' || true)
echo "SPF        : ${spf:-MISSING}"

# ---- DKIM ------------------------------------------------------------------
dkim_raw=$("${AUTH[@]}" TXT "${selector}._domainkey.${domain}")
dkim=$(echo "$dkim_raw" | tr -d '"' | tr -d ' ')
if [ -n "$dkim" ]; then
  echo "DKIM       : present at ${selector}._domainkey (${#dkim} chars)"
  echo "             p= ${dkim#*p=}" | cut -c1-78
  # Propagation, reported separately and never used for the verdict.
  pub=$(dig +short @8.8.8.8 TXT "${selector}._domainkey.${domain}" | tr -d '"' | tr -d ' ')
  if [ "$pub" = "$dkim" ]; then
    echo "             public resolver agrees"
  elif [ -z "$pub" ]; then
    echo "             public resolver has nothing yet — propagating"
  else
    echo "             public resolver differs — a cache node still holds the previous"
    echo "             record. Not a failure; recheck after the old TTL expires."
  fi
else
  echo "DKIM       : MISSING at ${selector}._domainkey.${domain}"
  status=1
fi

# The failure that looks like success: the key pasted into the apex, where no
# verifier will ever read it. Found on two live domains this way.
if echo "$apex" | grep -q 'v=DKIM1'; then
  echo "             ⚠ a DKIM string is also in the APEX TXT — inert there."
  echo "               Nothing reads it. It is what made broken domains look configured."
  status=1
fi

# ---- DMARC -----------------------------------------------------------------
dmarc=$("${AUTH[@]}" TXT "_dmarc.${domain}" | tr -d '"')
echo "DMARC      : ${dmarc:-MISSING}"
case "$dmarc" in
  *p=reject*)     echo "             blast radius: HIGH — a bad key loses mail." ;;
  *p=quarantine*) echo "             blast radius: MEDIUM — a bad key sends mail to spam." ;;
  *p=none*)       echo "             blast radius: LOW — a bad key shows up in reports only." ;;
esac

hr "verdict"
[ "$status" -eq 0 ] && echo "clean" || echo "issues found — see above"
exit "$status"
