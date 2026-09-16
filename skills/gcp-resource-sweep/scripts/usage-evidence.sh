#!/usr/bin/env bash
#
# Gathers usage evidence for named GCP resources. **Read-only.**
#
#   usage-evidence.sh names.txt [search-root ...]
#   gcloud secrets list --format='value(name)' | usage-evidence.sh - ~/ ~/Projects
#
# Answers the one question a resource name cannot: is anything using this?
# Google does not log reads unless Data Access audit logging was enabled, so
# there is usually no history to consult. Evidence comes from two places
# instead, and they are not equal:
#
#   BOUND      a deployed service mounts it. Decisive. Do not touch.
#   BY-NAME    a repository names it as a resource — a real binding in IaC or
#              deploy config, but possibly for something not deployed.
#   env-only   the SCREAMING_SNAKE form appears. Weak: the variable could be
#              set from anywhere, by anything.
#   unused     no reference found anywhere searched.
#
# "unused" means "not found in what was searched" and nothing stronger. Only
# repositories checked out locally are visible here; say so in the record.
set -euo pipefail

LIST="${1:-}"
[ -n "$LIST" ] || { echo "usage: usage-evidence.sh <names-file|-> [search-root ...]" >&2; exit 1; }
shift
ROOTS=("$@")
[ "${#ROOTS[@]}" -gt 0 ] || ROOTS=("$HOME/{{workspace_root}}" "$HOME/Projects")
PROJECT="${GCP_PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
if [ "$LIST" = "-" ]; then cat > "$work/names"; else cat "$LIST" > "$work/names"; fi
grep -c . "$work/names" >/dev/null || { echo "no names given" >&2; exit 1; }

# Both forms, one grep pass per root rather than one per name — the difference
# between seconds and ten minutes on a real project.
awk 'NF{print; u=toupper($0); gsub(/-/,"_",u); print u}' "$work/names" > "$work/patterns"

: > "$work/matched"
for root in "${ROOTS[@]}"; do
  [ -d "$root" ] || continue
  grep -rIoh --exclude-dir={node_modules,.git,dist,build,.next,coverage,__pycache__,.venv} \
    -F -f "$work/patterns" "$root" 2>/dev/null >> "$work/matched" || true
done
sort -u "$work/matched" > "$work/found"

# What is actually deployed outranks every grep above.
: > "$work/bound"
if [ -n "$PROJECT" ]; then
  for svc in $(gcloud run services list --project="$PROJECT" --format='value(SERVICE)' </dev/null 2>/dev/null); do
    region=$(gcloud run services list --project="$PROJECT" --filter="metadata.name=$svc" \
      --format='value(REGION)' </dev/null 2>/dev/null | head -1)
    gcloud run services describe "$svc" --project="$PROJECT" --region="$region" \
      --format='value(spec.template.spec.containers[].env)' </dev/null 2>/dev/null \
      | grep -oE "'name': '[^']+'" | sed "s/'name': '//;s/'//" \
      | while read -r ref; do echo "$ref	$svc"; done >> "$work/bound" || true
  done
fi

printf '%-42s %-10s %s\n' 'RESOURCE' 'VERDICT' 'EVIDENCE'
printf '%-42s %-10s %s\n' '------------------------------------------' '----------' '--------'
while read -r name; do
  [ -n "$name" ] || continue
  env_form="$(printf '%s' "$name" | tr 'a-z-' 'A-Z_')"
  # awk rather than `grep -P "^\Q$name\E\t"`, which returned nothing here and
  # took umami's two live bindings with it. The isolated case reproduces fine,
  # so the cause is unconfirmed — what matters is the failure shape: it failed
  # *silently* into an empty result, which reads as "not bound", and that is the
  # one wrong answer this script must never give. awk is exact and portable.
  svc="$(awk -F'\t' -v n="$name" '$1==n{print $2}' "$work/bound" | sort -u | paste -sd, - || true)"
  if [ -n "$svc" ]; then
    printf '%-42s %-10s %s\n' "$name" 'BOUND' "deployed: $svc"
  elif grep -qxF "$name" "$work/found"; then
    printf '%-42s %-10s %s\n' "$name" 'BY-NAME' 'named in a repository — check whether it deploys'
  elif grep -qxF "$env_form" "$work/found"; then
    printf '%-42s %-10s %s\n' "$name" 'env-only' "$env_form appears; source unknown"
  else
    printf '%-42s %-10s %s\n' "$name" 'unused' 'no reference in the roots searched'
  fi
done < "$work/names"
