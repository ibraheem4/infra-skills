#!/usr/bin/env bash
# Manage console-managed OAuth provider secrets in AWS Secrets Manager.
#
# These hold the Google/Microsoft client credentials that the identity provider
# consumes — not the application. Nothing deployed reads them, so they are
# deliberately created and populated out of band rather than by Terraform.
#
# Naming is the caller's convention, commonly <scope>/<env>/<service>-oauth.
#
# No secret value is ever echoed, passed in argv, or left on disk.
set -euo pipefail
case "$-" in *x*) echo "refusing to run under set -x" >&2; exit 1;; esac

# All three come from the environment. There are no defaults on purpose: a
# wrong-account default is worse than a missing one, because it fails late.
PROFILE="${AWS_PROFILE:?set AWS_PROFILE to the profile that owns the secret}"
REGION="${AWS_REGION:?set AWS_REGION}"
KMS_ALIAS="${KMS_ALIAS:?set KMS_ALIAS to the per-env CMK alias, never the default aws/secretsmanager key}"
SSO_SESSION="${AWS_SSO_SESSION:-<your sso session>}"

aws_() { aws --profile "$PROFILE" --region "$REGION" "$@"; }

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need aws; need jq

# Staging file for secret JSON. Must be global: a function-local would be out of
# scope when the EXIT trap fires, and `set -u` would abort the trap before the rm,
# leaving the plaintext value in $TMPDIR.
_TMP=""
_cleanup() { [ -n "${_TMP:-}" ] && rm -f "$_TMP" "$_TMP.new" "$_TMP.req"; return 0; }
trap _cleanup EXIT INT TERM
_stage() { umask 077; _TMP="$(mktemp)"; }

preflight() {
  aws_ sts get-caller-identity >/dev/null 2>&1 || {
    echo "Not signed in for profile $PROFILE." >&2
    echo "    Run: aws sso login --sso-session $SSO_SESSION" >&2
    exit 1
  }
}

usage() {
  cat >&2 <<USAGE
usage: $0 <command> [args]

  create <secret-id>              Create the secret under the per-env CMK ($KMS_ALIAS)
  keys   <secret-id>              List key names only (never values)
  put    <secret-id> <key>...     Prompt for each key (hidden), merge into existing JSON
  put-stdin <secret-id> <key>     Read one value from stdin, merge into existing JSON
  copy   <secret-id> <key>        Copy one value to the clipboard; prints nothing
  arn    <secret-id>              Print the secret ARN

env: AWS_PROFILE=$PROFILE  AWS_REGION=$REGION  KMS_ALIAS=$KMS_ALIAS
     AWS_SSO_SESSION=$SSO_SESSION
USAGE
  exit 2
}

cmd_create() {
  aws_ secretsmanager create-secret \
    --name "$1" \
    --description "OAuth provider credentials (console-managed, not in Terraform)" \
    --kms-key-id "$KMS_ALIAS" \
    --secret-string '{}' \
    --query 'ARN' --output text
}

cmd_keys() {
  aws_ secretsmanager get-secret-value --secret-id "$1" \
    --query SecretString --output text | jq -r 'keys[]'
}

cmd_arn() {
  aws_ secretsmanager describe-secret --secret-id "$1" --query ARN --output text
}

# Load the secret's current JSON into $2, or {} when it has no version yet.
_load_existing() {
  local id="$1" out="$2"
  if aws_ secretsmanager get-secret-value --secret-id "$id" \
       --query SecretString --output text > "$out" 2>/dev/null; then
    :
  else
    echo '{}' > "$out"
  fi
  jq -e 'type == "object"' "$out" >/dev/null || { echo "$id is not a JSON object" >&2; exit 1; }
}

# Write staged JSON back. --cli-input-json from a file keeps the value out of argv and ps.
_put() {
  local id="$1" src="$2"
  jq -n --arg id "$id" --rawfile s "$src" '{SecretId:$id, SecretString:$s}' > "$src.req"
  aws_ secretsmanager put-secret-value --cli-input-json "file://$src.req" \
    --query 'VersionId' --output text
  rm -f "$src.req"
}

cmd_put() {
  local id="$1"; shift
  [ "$#" -gt 0 ] || usage

  _stage
  local tmp="$_TMP"

  # Start from the existing payload so sibling keys survive.
  _load_existing "$id" "$tmp"

  local key val
  for key in "$@"; do
    printf 'value for %s (hidden, empty to skip): ' "$key" >&2
    IFS= read -rs val; printf '\n' >&2
    [ -n "$val" ] || { echo "  skipped $key" >&2; continue; }
    jq --arg k "$key" --arg v "$val" '.[$k] = $v' "$tmp" > "$tmp.new" && mv -f "$tmp.new" "$tmp"
    unset val
    echo "  staged $key" >&2
  done

  _put "$id" "$tmp"
  echo "keys now in $id:" >&2
  jq -r 'keys[]' "$tmp" | sed 's/^/  /' >&2
}

# Non-interactive single-key write, for piping a value that must never be displayed:
#   az ad app credential reset --query password -o tsv | oauth-secrets.sh put-stdin <id> <key>
cmd_put_stdin() {
  local id="$1" key="$2"

  _stage
  local tmp="$_TMP"

  local val; IFS= read -r val || true
  [ -n "$val" ] || { echo "no value on stdin for $key" >&2; exit 1; }

  _load_existing "$id" "$tmp"
  jq --arg k "$key" --arg v "$val" '.[$k] = $v' "$tmp" > "$tmp.new" && mv -f "$tmp.new" "$tmp"
  unset val

  _put "$id" "$tmp" >/dev/null
  echo "  wrote $key to $id" >&2
}

cmd_copy() {
  local id="$1" key="$2" clip
  if command -v pbcopy >/dev/null; then clip=pbcopy
  elif command -v wl-copy >/dev/null; then clip=wl-copy
  elif command -v xclip  >/dev/null; then clip="xclip -selection clipboard"
  else echo "no clipboard tool found" >&2; exit 1; fi

  aws_ secretsmanager get-secret-value --secret-id "$id" \
    --query SecretString --output text \
  | jq -er --arg k "$key" '.[$k] // error("no such key: \($k)")' \
  | tr -d '\n' | $clip
  echo "copied $id → $key to the clipboard" >&2
}

[ "$#" -ge 1 ] || usage
sub="$1"; shift
case "$sub" in
  create) [ "$#" -eq 1 ] || usage; preflight; cmd_create "$@" ;;
  keys)   [ "$#" -eq 1 ] || usage; preflight; cmd_keys   "$@" ;;
  arn)    [ "$#" -eq 1 ] || usage; preflight; cmd_arn    "$@" ;;
  put)    [ "$#" -ge 2 ] || usage; preflight; cmd_put    "$@" ;;
  put-stdin) [ "$#" -eq 2 ] || usage; preflight; cmd_put_stdin "$@" ;;
  copy)   [ "$#" -eq 2 ] || usage; preflight; cmd_copy   "$@" ;;
  *) usage ;;
esac
