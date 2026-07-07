#!/usr/bin/env bash
set -euo pipefail

CONFIG="${HOME}/.aws/config"
BACKUP="${HOME}/.aws/config.bak.$(date +%Y%m%d%H%M%S)"

# Default region for generated profiles (workloads, e.g. EC2/S3 calls)
DEFAULT_REGION="${DEFAULT_REGION:-eu-west-2}"

# sso-session name to use: first positional arg, else $SESSION_NAME, else default
SESSION_NAME="${1:-${SESSION_NAME:-corp-sso}}"

JQ_BIN="${JQ_BIN:-jq}"

command -v aws >/dev/null || { echo "aws CLI not found"; exit 1; }
command -v "$JQ_BIN" >/dev/null || { echo "jq not found"; exit 1; }

mkdir -p "$(dirname "$CONFIG")"
touch "$CONFIG"

echo "Using sso-session: $SESSION_NAME"

# Read sso_region (Identity Center region) from the sso-session block
SSO_REGION="$(awk -v s="$SESSION_NAME" '
  $0=="[sso-session "s"]"{f=1;next}
  /^\[/{f=0}
  f && $1=="sso_region" {print $3; exit}
' "$CONFIG" || true)"

if [[ -z "$SSO_REGION" ]]; then
  echo "Could not find sso_region in [sso-session $SESSION_NAME] in $CONFIG"
  echo "Create/fix it with: aws configure sso-session $SESSION_NAME"
  exit 1
fi

echo "Identity Center region: $SSO_REGION"

# Ensure you’re logged in (region matters for SSO login too)
aws sso login --sso-session "$SESSION_NAME" --region "$SSO_REGION" >/dev/null || true

# Grab the freshest access token from cache
TOKEN=$(
  "$JQ_BIN" -r '
    select(.accessToken) | [.expiresAt, .accessToken] | @tsv
  ' "$HOME"/.aws/sso/cache/*.json 2>/dev/null \
  | sort -r | head -n1 | cut -f2
)

if [[ -z "${TOKEN:-}" ]]; then
  echo "No SSO access token found in ~/.aws/sso/cache."
  echo "Try: rm -f ~/.aws/sso/cache/*.json && aws sso login --sso-session $SESSION_NAME --region $SSO_REGION"
  exit 1
fi

# Backup and start from current config, stripping any profile blocks
# this script previously generated (identified by sso_session = $SESSION_NAME).
# Manually-curated profiles and the [sso-session ...] block are preserved.
cp "$CONFIG" "$BACKUP"
echo "Backed up existing config to $BACKUP"
TMP="$(mktemp)"
awk -v session="$SESSION_NAME" '
  function flush() {
    if (in_profile && keep) printf "%s", buf
    in_profile = 0; buf = ""; keep = 1
  }
  /^\[profile / {
    flush()
    in_profile = 1; buf = $0 "\n"; keep = 1
    next
  }
  /^\[/ {
    flush()
    print
    next
  }
  {
    if (in_profile) {
      buf = buf $0 "\n"
      if ($1 == "sso_session" && $3 == session) keep = 0
    } else {
      print
    }
  }
  END { flush() }
' "$BACKUP" > "$TMP"

sanitize() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' | sed 's/^-*//; s/-*$//'
}

# Enumerate accounts and roles using the SSO region
aws sso list-accounts --region "$SSO_REGION" --access-token "$TOKEN" --output json \
| "$JQ_BIN" -r '.accountList[] | [.accountId, .accountName] | @tsv' \
| while IFS=$'\t' read -r acctId acctName; do
    safeName="$(sanitize "$acctName")"
    aws sso list-account-roles --region "$SSO_REGION" --access-token "$TOKEN" --account-id "$acctId" --output json \
    | "$JQ_BIN" -r '.roleList[].roleName' \
    | while read -r role; do
        {
          echo ""
          echo "[profile ${safeName}-${role}]"
          echo "sso_session = ${SESSION_NAME}"
          echo "sso_account_id = ${acctId}"
          echo "sso_role_name = ${role}"
          echo "region = ${DEFAULT_REGION}"
          echo "output = json"
        } >> "$TMP"
      done
  done

mv "$TMP" "$CONFIG"
echo "Wrote merged config to $CONFIG"
echo "Try:"
echo "  aws sts get-caller-identity --profile <account-name>-<RoleName>"

